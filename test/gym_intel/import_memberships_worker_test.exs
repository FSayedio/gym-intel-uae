defmodule GymIntel.ImportMembershipsWorkerTest do
  use ExUnit.Case, async: true
  use Oban.Testing, repo: GymIntel.Repo

  alias GymIntel.{MembershipCSV, Workers.ImportMemberships}

  test "jobs target the imports queue with three attempts" do
    job = ImportMemberships.new(%{"csv" => "test"}) |> Ecto.Changeset.apply_changes()
    assert job.queue == "imports"
    assert job.max_attempts == 3
  end

  test "invalid CSV is cancelled rather than retried" do
    assert {:cancel, :header_mismatch} = perform_job(ImportMemberships, %{"csv" => "wrong\n"})
    # Oban's JSON round-trip cannot encode invalid UTF-8; exercise the defensive
    # worker boundary directly. File-based rejection is tested before enqueue.
    assert {:cancel, :invalid_utf8} =
             ImportMemberships.perform(%Oban.Job{args: %{"csv" => <<255>>}})
  end

  @tag :tmp_dir
  test "invalid-row and missing-file enqueue errors return without database access", %{
    tmp_dir: dir
  } do
    path = Path.join(dir, "rejected.csv")

    contents =
      Enum.join(MembershipCSV.headers(), ",") <>
        "\nTEST ONLY,,TEST,all_uae_branches,,2e2,1,,,https://example.com,,2026-09-12,,,,,\n"

    File.write!(path, contents)

    assert {:error, {:rows, [%{errors: %{advertised_price_aed: _}}]}} =
             ImportMemberships.enqueue_file(path)

    assert {:error, {:file, :enoent}} =
             ImportMemberships.enqueue_file(Path.join(dir, "missing.csv"))
  end

  test "header-only CSV completes as an empty import" do
    header = Enum.join(MembershipCSV.headers(), ",") <> "\n"
    assert {:ok, :empty} = perform_job(ImportMemberships, %{"csv" => header})
  end

  test "missing or oversized CSV arguments are cancelled" do
    assert {:cancel, :invalid_arguments} = perform_job(ImportMemberships, %{})

    assert {:cancel, :csv_too_large} =
             perform_job(ImportMemberships, %{"csv" => String.duplicate("x", 1_000_001)})
  end
end
