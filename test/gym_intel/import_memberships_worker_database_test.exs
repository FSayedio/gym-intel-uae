defmodule GymIntel.ImportMembershipsWorkerDatabaseTest do
  use ExUnit.Case, async: false
  use Oban.Testing, repo: GymIntel.Repo

  alias GymIntel.{Membership, MembershipCSV, Repo, Workers.ImportMemberships}

  @moduletag :database

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    start_supervised!({Oban, repo: Repo, testing: :manual, queues: false, plugins: false})
    :ok
  end

  defp csv do
    Enum.join(MembershipCSV.headers(), ",") <>
      "\nTEST WORKER,,Synthetic plan,all_uae_branches,,100,1,,,https://example.com,,2026-09-12,TEST ONLY\n"
  end

  @tag :tmp_dir
  test "enqueue stores a snapshot, not a path to a mutable file", %{tmp_dir: dir} do
    path = Path.join(dir, "synthetic.csv")
    File.write!(path, csv())
    assert {:ok, job} = ImportMemberships.enqueue_file(path)
    File.write!(path, "changed after enqueue")

    stored = Repo.get!(Oban.Job, job.id)
    assert stored.args == %{"csv" => csv()}
    assert stored.state == "available"
    assert Repo.aggregate(Membership, :count) == 0

    assert {:ok, {:imported, %{inserted: 1, skipped: 0}}} =
             perform_job(ImportMemberships, stored.args)

    assert Repo.aggregate(Membership, :count) == 1
    assert {:ok, :already_imported} = perform_job(ImportMemberships, stored.args)
    assert Repo.aggregate(Membership, :count) == 1
  end

  test "invalid row cancels without inserting memberships" do
    invalid = String.replace(csv(), ",100,1,", ",100,,")
    assert {:cancel, {:rows, [_]}} = perform_job(ImportMemberships, %{"csv" => invalid})
    assert Repo.aggregate(Membership, :count) == 0
  end
end
