defmodule GymIntel.SourceMonitorDatabaseTest do
  use ExUnit.Case, async: false
  import Ecto.Query
  alias GymIntel.{Repo, SourceMonitor}
  @moduletag :database
  @source %{
    id: "test_offer",
    gym: "Test gym",
    label: "Synthetic only",
    url: "https://example.com/test",
    anchors: ["test gym", "monthly"],
    coverage: "Test only"
  }

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
  end

  defp check(price) do
    SourceMonitor.check(
      sources: [@source],
      fetch: fn _ ->
        {:ok, "<main>Test gym monthly membership costs AED #{price} for gym access.</main>"}
      end
    )
  end

  defp result(report), do: hd(report["sources"])

  test "changed evidence survives two-report retention until reviewed; no gym rows or dates change" do
    before_rows = Repo.query!("SELECT * FROM memberships ORDER BY id").rows
    assert {:ok, first} = check(199)
    assert result(first)["status"] == "baseline"
    assert result(first)["review_required"]
    hash = result(first)["hash"]
    assert :ok = SourceMonitor.acknowledge(@source.id, hash)
    assert {:ok, changed} = check(219)
    assert result(changed)["status"] == "page_changed"
    assert {:error, :baseline_changed_or_missing} = SourceMonitor.acknowledge(@source.id, hash)
    assert {:ok, _} = check(219)
    assert {:ok, same} = check(219)
    assert length(SourceMonitor.reports()) == 2
    assert result(same)["status"] == "page_unchanged"
    assert result(same)["review_required"]
    assert result(same)["change_excerpt"]["before"] =~ "199"
    assert result(same)["change_excerpt"]["after"] =~ "219"
    assert :ok = SourceMonitor.acknowledge(@source.id, result(same)["hash"])
    assert {:ok, acknowledged} = check(219)
    refute result(acknowledged)["review_required"]
    refute result(acknowledged)["offer_verified"]
    assert result(acknowledged)["change_excerpt"] == nil
    assert Repo.query!("SELECT * FROM memberships ORDER BY id").rows == before_rows
  end

  test "repeated failures retain the last usable baseline and are never reported as unchanged" do
    {:ok, first} = check(199)
    hash = result(first)["hash"]

    for _ <- 1..3 do
      assert {:ok, failed} =
               SourceMonitor.check(
                 sources: [@source],
                 fetch: fn _ -> {:error, {:http_status, 403}} end
               )

      assert result(failed)["status"] == "check_failed"
      assert result(failed)["review_required"]
    end

    assert [%{hash: ^hash}] = SourceMonitor.states()
    assert length(SourceMonitor.reports()) == 2
    assert {:ok, changed} = check(219)
    assert result(changed)["status"] == "page_changed"
    assert result(changed)["previous_hash"] == hash
  end

  test "job retention only removes old terminal source checks, never imports or unfinished work" do
    completed =
      for _ <- 1..4 do
        Repo.insert!(%Oban.Job{
          worker: "GymIntel.Workers.CheckSources",
          queue: "source_checks",
          args: %{},
          state: "completed"
        })
      end

    pending =
      Repo.insert!(%Oban.Job{
        worker: "GymIntel.Workers.CheckSources",
        queue: "source_checks",
        args: %{},
        state: "available"
      })

    import_job =
      Repo.insert!(%Oban.Job{
        worker: "GymIntel.Workers.ImportMemberships",
        queue: "imports",
        args: %{},
        state: "completed"
      })

    assert {:ok, _} = check(199)

    assert Repo.aggregate(
             from(j in Oban.Job,
               where: j.worker == "GymIntel.Workers.CheckSources" and j.state == "completed"
             ),
             :count
           ) == 2

    assert Repo.get(Oban.Job, pending.id)
    assert Repo.get(Oban.Job, import_job.id)
    refute Repo.get(Oban.Job, hd(completed).id)
  end

  test "database failure rolls back the partial report and state updates" do
    bad = Map.put(@source, :id, "second")

    assert_raise RuntimeError, "synthetic failure", fn ->
      SourceMonitor.check(
        sources: [@source, bad],
        fetch: fn _ ->
          if Repo.aggregate("source_check_states", :count, :source_id) == 0,
            do: {:ok, "Test gym monthly membership AED 199 with gym access included."},
            else: raise("synthetic failure")
        end
      )
    end

    assert SourceMonitor.states() == []
    assert SourceMonitor.reports() == []
  end

  test "failed worker attempt still prunes old terminal jobs outside the report transaction" do
    for _ <- 1..4 do
      Repo.insert!(%Oban.Job{
        worker: "GymIntel.Workers.CheckSources",
        queue: "source_checks",
        args: %{},
        state: "discarded"
      })
    end

    running =
      Repo.insert!(%Oban.Job{
        worker: "GymIntel.Workers.CheckSources",
        queue: "source_checks",
        args: %{},
        state: "executing"
      })

    assert_raise RuntimeError, "synthetic failure", fn ->
      SourceMonitor.check(
        job_id: running.id,
        sources: [@source],
        fetch: fn _ -> raise "synthetic failure" end
      )
    end

    assert Repo.aggregate(
             from(j in Oban.Job,
               where: j.worker == "GymIntel.Workers.CheckSources" and j.state == "discarded"
             ),
             :count
           ) == 1

    assert Repo.get(Oban.Job, running.id).state == "executing"
    assert SourceMonitor.states() == []
    assert SourceMonitor.reports() == []
  end
end
