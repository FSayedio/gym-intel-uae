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

  defp perform_import(args) do
    job =
      ImportMemberships.new(args)
      |> Ecto.Changeset.change(state: "executing", attempt: 1, attempted_at: DateTime.utc_now())
      |> Repo.insert!()

    ImportMemberships.perform(job)
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
             perform_import(stored.args)

    assert Repo.aggregate(Membership, :count) == 1
    assert {:ok, :already_imported} = perform_import(stored.args)
    assert Repo.aggregate(Membership, :count) == 1
  end

  test "invalid row cancels without inserting memberships" do
    invalid = String.replace(csv(), ",100,1,", ",100,,")
    assert {:cancel, {:rows, [_]}} = perform_import(%{"csv" => invalid})
    assert Repo.aggregate(Membership, :count) == 0
  end

  @tag :tmp_dir
  test "padded snapshots deduplicate names but retain raw bytes and genuinely different facts", %{
    tmp_dir: dir
  } do
    [header, row] = NimbleCSV.RFC4180.parse_string(csv(), skip_headers: false)
    notes = " \tSource notes\n remain unchanged \n"

    row =
      row
      |> List.replace_at(1, "TEST BRANCH")
      |> List.replace_at(3, "single_branch")
      |> List.replace_at(12, notes)

    encode = fn rows ->
      [header | rows]
      |> NimbleCSV.RFC4180.dump_to_iodata()
      |> IO.iodata_to_binary()
    end

    assert {:ok, {:imported, %{inserted: 1, skipped: 0}}} =
             perform_import(%{"csv" => encode.([row])})

    original = Repo.one!(Membership)

    padded_row =
      row
      |> Enum.with_index()
      |> Enum.map(fn {value, index} ->
        if index in 0..2, do: "\u00A0 \t" <> value <> "\r\n ", else: value
      end)

    contents = encode.([padded_row])
    path = Path.join(dir, "padded.csv")
    File.write!(path, contents)
    assert {:ok, job} = ImportMemberships.enqueue_file(path)
    stored = Repo.get!(Oban.Job, job.id)
    assert stored.args == %{"csv" => contents}

    assert {:ok, {:imported, %{inserted: 0, skipped: 1}}} = perform_import(stored.args)
    assert Repo.one!(Membership).id == original.id
    assert Repo.one!(Membership).observation_key == original.observation_key
    assert Repo.one!(Membership).notes == notes
    assert %{rows: [[1]]} = Repo.query!("SELECT count(*) FROM membership_notes")
    assert %{rows: [[2]]} = Repo.query!("SELECT count(*) FROM membership_imports")

    changed_price = encode.([List.replace_at(padded_row, 5, "101")])

    assert {:ok, {:imported, %{inserted: 1, skipped: 0}}} =
             perform_import(%{"csv" => changed_price})

    price_record = Repo.get_by!(Membership, advertised_price_aed: Decimal.new("101"))
    refute price_record.observation_key == original.observation_key

    internal_space = encode.([List.replace_at(padded_row, 2, " Synthetic  plan ")])

    assert {:ok, {:imported, %{inserted: 1, skipped: 0}}} =
             perform_import(%{"csv" => internal_space})

    assert Repo.get_by!(Membership, plan_name: "Synthetic  plan")
    assert Repo.aggregate(Membership, :count) == 3
    assert %{rows: [[4]]} = Repo.query!("SELECT count(*) FROM membership_imports")
  end

  test "255-code-point names survive the worker and database without truncation" do
    [header, row] = NimbleCSV.RFC4180.parse_string(csv(), skip_headers: false)
    names = [String.duplicate("ن", 255), String.duplicate("e\u0301", 127) <> "e"]

    rows =
      for index <- 0..2, name <- names do
        List.replace_at(row, index, name)
      end

    contents =
      [header | rows]
      |> NimbleCSV.RFC4180.dump_to_iodata()
      |> IO.iodata_to_binary()

    assert {:ok, {:imported, %{inserted: 6, skipped: 0}}} =
             perform_import(%{"csv" => contents})

    records = Repo.all(Membership)

    for field <- [:brand_name, :branch_name, :plan_name], name <- names do
      assert Enum.any?(records, &(Map.fetch!(&1, field) == name))
    end
  end

  @tag :tmp_dir
  test "a mixed CSV with an oversized name creates no job, membership, note or receipt", %{
    tmp_dir: dir
  } do
    path = Path.join(dir, "oversized-name.csv")
    [header, row] = NimbleCSV.RFC4180.parse_string(csv(), skip_headers: false)

    for {field, index} <- [{:brand_name, 0}, {:branch_name, 1}, {:plan_name, 2}] do
      contents =
        [header, row, List.replace_at(row, index, String.duplicate("A", 256))]
        |> NimbleCSV.RFC4180.dump_to_iodata()
        |> IO.iodata_to_binary()

      File.write!(path, contents)

      assert {:error, {:rows, [%{record: 3, errors: errors}]}} =
               ImportMemberships.enqueue_file(path)

      assert errors[field] == ["should be at most 255 character(s)"]
      assert Repo.aggregate(Oban.Job, :count) == 0
      assert Repo.aggregate(Membership, :count) == 0
      assert %{rows: [[0]]} = Repo.query!("SELECT count(*) FROM membership_notes")
      assert %{rows: [[0]]} = Repo.query!("SELECT count(*) FROM membership_imports")
    end
  end

  test "an already-queued snapshot with an oversized name is cancelled before any writes" do
    [header, row] = NimbleCSV.RFC4180.parse_string(csv(), skip_headers: false)

    contents =
      [header, row, List.replace_at(row, 2, String.duplicate("e\u0301", 128))]
      |> NimbleCSV.RFC4180.dump_to_iodata()
      |> IO.iodata_to_binary()

    assert {:cancel, {:rows, [%{record: 3, errors: errors}]}} =
             perform_import(%{"csv" => contents})

    assert errors.plan_name == ["should be at most 255 character(s)"]
    assert Repo.aggregate(Membership, :count) == 0
    assert %{rows: [[0]]} = Repo.query!("SELECT count(*) FROM membership_notes")
    assert %{rows: [[0]]} = Repo.query!("SELECT count(*) FROM membership_imports")
  end

  @tag :tmp_dir
  test "oversized or invalid-encoding files create no queued job or imported data", %{
    tmp_dir: dir
  } do
    path = Path.join(dir, "invalid.csv")
    jobs_before = Repo.aggregate(Oban.Job, :count)
    rows_before = Repo.aggregate(Membership, :count)
    %{rows: [[imports_before]]} = Repo.query!("SELECT count(*) FROM membership_imports")

    for {contents, reason} <- [
          {String.duplicate("x", MembershipCSV.max_bytes() + 1), :csv_too_large},
          {<<255>>, :invalid_utf8}
        ] do
      File.write!(path, contents)
      assert {:error, ^reason} = ImportMemberships.enqueue_file(path)
      assert Repo.aggregate(Oban.Job, :count) == jobs_before
      assert Repo.aggregate(Membership, :count) == rows_before
      assert %{rows: [[^imports_before]]} = Repo.query!("SELECT count(*) FROM membership_imports")
    end

    credential_url = String.replace(csv(), "example.com", "test-user:test-only@example.com")
    File.write!(path, credential_url)
    assert {:error, {:rows, [%{errors: %{source_url: _}}]}} = ImportMemberships.enqueue_file(path)
    assert Repo.aggregate(Oban.Job, :count) == jobs_before
    assert Repo.aggregate(Membership, :count) == rows_before
    assert %{rows: [[^imports_before]]} = Repo.query!("SELECT count(*) FROM membership_imports")
  end

  test "hardening errors cancel the worker without a partial import or fingerprint" do
    invalid = String.replace(csv(), ",100,1,", ",100.001,1,")
    assert {:cancel, {:rows, [_]}} = perform_import(%{"csv" => invalid})
    assert Repo.aggregate(Membership, :count) == 0
    assert %{rows: [[0]]} = Repo.query!("SELECT count(*) FROM membership_imports")
  end

  @tag :tmp_dir
  test "enqueue preserves original export bytes while the worker accepts its formatting", %{
    tmp_dir: dir
  } do
    contents = <<0xEF, 0xBB, 0xBF>> <> String.replace(csv() <> "\n\n", "\n", "\r\n")
    path = Path.join(dir, "export.csv")
    File.write!(path, contents)
    assert {:ok, job} = ImportMemberships.enqueue_file(path)
    assert Repo.get!(Oban.Job, job.id).args == %{"csv" => contents}

    assert {:ok, {:imported, %{inserted: 1, skipped: 0}}} =
             perform_import(job.args)
  end

  test "legacy queued snapshots still execute after the CSV extension" do
    [header, row] = String.split(csv(), "\n", trim: true)
    header = header |> String.split(",") |> Enum.take(13) |> Enum.join(",")
    legacy_row = row |> String.split(",") |> Enum.take(13) |> Enum.join(",")
    legacy = header <> "\n" <> legacy_row <> "\n"

    assert {:ok, {:imported, %{inserted: 1, skipped: 0}}} =
             perform_import(%{"csv" => legacy})

    record = Repo.one!(Membership)
    assert record.payment_structure == nil
    assert record.renewal_policy == nil
  end

  test "worker persists the snapshot's explicit payment and renewal without inferring a relationship" do
    contents = String.replace(csv(), "TEST ONLY,,", "TEST ONLY,prepaid_term,automatic")

    assert {:ok, {:imported, %{inserted: 1, skipped: 0}}} =
             perform_import(%{"csv" => contents})

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
             perform_import(%{"csv" => legacy})

    record = Repo.one!(Membership)
    assert record.payment_structure == "recurring"
    assert record.price_vat_status == nil
    assert record.admin_fee_aed == nil

    classified = String.replace(current, "automatic,,", "automatic,included,30")

    assert {:ok, {:imported, %{inserted: 1, skipped: 0}}} =
             perform_import(%{"csv" => classified})

    assert record = Repo.get_by!(Membership, price_vat_status: "included")
    assert Decimal.equal?(record.admin_fee_aed, Decimal.new("30"))
  end
end
