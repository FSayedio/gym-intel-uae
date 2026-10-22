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
      "\nTEST WORKER,,Synthetic plan,all_uae_branches,,100,1,,,https://example.com,,2026-09-12,TEST ONLY,,,,\n"
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

  test "legacy queued snapshots still execute after the CSV extension" do
    [header, row] = String.split(csv(), "\n", trim: true)
    header = header |> String.split(",") |> Enum.take(13) |> Enum.join(",")
    legacy_row = row |> String.split(",") |> Enum.take(13) |> Enum.join(",")
    legacy = header <> "\n" <> legacy_row <> "\n"

    assert {:ok, {:imported, %{inserted: 1, skipped: 0}}} =
             perform_job(ImportMemberships, %{"csv" => legacy})

    record = Repo.one!(Membership)
    assert record.payment_structure == nil
    assert record.renewal_policy == nil
  end

  test "worker persists the snapshot's explicit payment and renewal without inferring a relationship" do
    contents = String.replace(csv(), "TEST ONLY,,", "TEST ONLY,prepaid_term,automatic")

    assert {:ok, {:imported, %{inserted: 1, skipped: 0}}} =
             perform_job(ImportMemberships, %{"csv" => contents})

    record = Repo.one!(Membership)
    assert record.payment_structure == "prepaid_term"
    assert record.renewal_policy == "automatic"
  end

  test "payment-era queued snapshots retain unknown VAT/admin and new snapshots retain explicit facts" do
    current = String.replace(csv(), "TEST ONLY,,,,", "TEST ONLY,recurring,automatic,,")

    legacy =
      current
      |> NimbleCSV.RFC4180.parse_string(skip_headers: false)
      |> Enum.map(&Enum.take(&1, 15))
      |> NimbleCSV.RFC4180.dump_to_iodata()
      |> IO.iodata_to_binary()

    assert {:ok, {:imported, %{inserted: 1, skipped: 0}}} =
             perform_job(ImportMemberships, %{"csv" => legacy})

    record = Repo.one!(Membership)
    assert record.payment_structure == "recurring"
    assert record.price_vat_status == nil
    assert record.admin_fee_aed == nil

    classified = String.replace(current, "automatic,,", "automatic,included,30")

    assert {:ok, {:imported, %{inserted: 1, skipped: 0}}} =
             perform_job(ImportMemberships, %{"csv" => classified})

    assert record = Repo.get_by!(Membership, price_vat_status: "included")
    assert Decimal.equal?(record.admin_fee_aed, Decimal.new("30"))
  end
end
