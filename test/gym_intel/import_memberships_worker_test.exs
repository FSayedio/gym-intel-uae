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
