defmodule GymIntel.UpdateLifecycleDatabaseTest do
  use ExUnit.Case, async: false
  alias GymIntel.{MembershipCSV, MembershipImporter, Repo}
  @moduletag :database

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    Repo.delete_all("membership_notes")
    Repo.delete_all("memberships")
    Repo.delete_all("membership_imports")
    Repo.delete_all("oban_jobs")
    Repo.query!(File.read!("priv/update_state.sql"))
    Repo.query!(File.read!("priv/update_cleanup.sql"))
    :ok
  end

  defp csv(day, price, brand \\ "TEST UPDATE") do
    Enum.join(MembershipCSV.headers(), ",") <>
      "\n#{brand},TEST BRANCH,TEST PLAN,single_branch,standard,#{price},1,0,0,https://example.com/update,,2000-01-0#{day},TEST ONLY,,,,\n"
  end

  defp sha(contents), do: :crypto.hash(:sha256, contents) |> Base.encode16(case: :lower)

  defp seed_import(contents) do
    assert {:ok, _} = MembershipImporter.import_csv(contents)
  end

  defp job(contents, state \\ "completed", worker \\ "GymIntel.Workers.ImportMemberships") do
    %{rows: [[id]]} =
      Repo.query!(
        """
        INSERT INTO oban_jobs(queue, worker, args, state, attempt, max_attempts,
          completed_at, cancelled_at, discarded_at)
        VALUES ('imports', $1, $2, $3::oban_job_state, 1, 3,
          CASE WHEN $3 = 'completed' THEN now() END,
          CASE WHEN $3 = 'cancelled' THEN now() END,
          CASE WHEN $3 = 'discarded' THEN now() END) RETURNING id
        """,
        [worker, %{"csv" => contents}, state]
      )

    id
  end

  defp state do
    %{rows: [[digest]]} = Repo.query!("SELECT pg_temp.dashboard_update_state()")
    digest
  end

  defp cleanup(id, csv, digest \\ state()) do
    Repo.query(
      "SELECT pg_temp.cleanup_dashboard_update($1, $2, $3)",
      [digest, id, sha(csv)],
      mode: :savepoint
    )
  end

  defp count(table), do: Repo.aggregate(table, :count)

  test "post-backup cleanup keeps current facts, two terminal jobs and tiny dedupe markers" do
    first = csv(1, 199)
    second = csv(2, 219)
    third = csv(3, 229)
    for contents <- [first, second, third], do: seed_import(contents)
    seed_import(csv(1, 150, "TEST UNRELATED"))
    old_job = job(first, "cancelled")
    second_job = job(second, "discarded")
    third_job = job(third)
    unrelated_job = job("TEST ONLY", "completed", "Other.Worker")

    assert {:ok, %{rows: [[result]]}} = cleanup(third_job, third)
    assert result["superseded_observations_removed"] == 2
    assert result["associated_notes_removed"] == 2
    assert result["finished_import_jobs_removed"] == 1
    assert count("memberships") == 2
    assert count("membership_notes") == 2
    assert count("membership_imports") == 4
    assert Repo.get(Oban.Job, old_job) == nil
    assert Repo.get(Oban.Job, second_job)
    assert Repo.get(Oban.Job, third_job)
    assert Repo.get(Oban.Job, unrelated_job)

    # A purged old observation cannot be resurrected by submitting the same file.
    assert {:ok, :already_imported} = MembershipImporter.import_csv(first)
    assert count("memberships") == 2
  end

  test "same-date conflicts and latest unknown survive, older compatible data does not" do
    for contents <- [csv(1, 100), csv(2, 200), csv(2, 210)], do: seed_import(contents)
    latest = csv(3, "", "TEST UNKNOWN")
    seed_import(csv(1, 80, "TEST UNKNOWN"))
    seed_import(latest)
    id = job(latest)
    assert {:ok, _} = cleanup(id, latest)
    assert count("memberships") == 3

    assert %{rows: [[nil]]} =
             Repo.query!(
               "SELECT advertised_price_aed FROM memberships WHERE brand_name = 'TEST UNKNOWN'"
             )
  end

  test "all unfinished states refuse cleanup and preserve facts and jobs" do
    latest = csv(2, 219)
    seed_import(csv(1, 199))
    seed_import(latest)
    id = job(latest)

    for pending <- ["available", "scheduled", "executing", "retryable"] do
      pending_id = job(latest, pending)
      assert {:error, %Postgrex.Error{postgres: %{message: message}}} = cleanup(id, latest)
      assert message =~ "Unfinished jobs"
      assert count("memberships") == 2
      Repo.delete!(Repo.get!(Oban.Job, pending_id))
    end
  end

  test "a write after backup preparation fails closed without deleting records" do
    latest = csv(2, 219)
    seed_import(csv(1, 199))
    seed_import(latest)
    id = job(latest)
    baseline = state()
    seed_import(csv(1, 50, "TEST LATE WRITE"))

    assert {:error, %Postgrex.Error{postgres: %{message: message}}} =
             cleanup(id, latest, baseline)

    assert message =~ "Database changed"
    assert count("memberships") == 3
  end

  test "completed job is insufficient without matching fingerprint evidence" do
    latest = csv(2, 219)
    seed_import(csv(1, 199))
    seed_import(latest)
    id = job(csv(2, 999))
    assert {:error, %Postgrex.Error{postgres: %{message: message}}} = cleanup(id, latest)
    assert message =~ "Missing matching"
    assert count("memberships") == 2
  end

  test "terminal retention uses finishing order, not scheduled time" do
    latest = csv(2, 219)
    seed_import(latest)
    old = job(latest)
    recent = job(latest)
    target = job(latest)

    Repo.query!("UPDATE oban_jobs SET completed_at = now() - interval '1 day' WHERE id = $1", [
      old
    ])

    Repo.query!("UPDATE oban_jobs SET scheduled_at = now() - interval '1 year' WHERE id = $1", [
      recent
    ])

    assert {:ok, _} = cleanup(target, latest)
    refute Repo.get(Oban.Job, old)
    assert Repo.get(Oban.Job, recent)
    assert Repo.get(Oban.Job, target)
  end

  test "failure during final job deletion rolls back observation and note cleanup" do
    latest = csv(2, 219)
    seed_import(csv(1, 199))
    seed_import(latest)
    job(latest)
    job(latest)
    id = job(latest)

    Repo.query!("""
    CREATE FUNCTION pg_temp.reject_job_cleanup() RETURNS trigger LANGUAGE plpgsql AS $$
    BEGIN RAISE EXCEPTION 'TEST ONLY reject terminal cleanup'; END $$
    """)

    Repo.query!("""
    CREATE TRIGGER test_reject_job_cleanup BEFORE DELETE ON public.oban_jobs
    FOR EACH STATEMENT EXECUTE FUNCTION pg_temp.reject_job_cleanup()
    """)

    assert {:error, %Postgrex.Error{postgres: %{message: message}}} = cleanup(id, latest)
    assert message =~ "TEST ONLY reject terminal cleanup"
    assert count("memberships") == 2
    assert count("membership_notes") == 2
    assert count("oban_jobs") == 3
  end
end
