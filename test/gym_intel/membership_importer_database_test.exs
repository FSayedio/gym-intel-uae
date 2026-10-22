defmodule GymIntel.MembershipImporterDatabaseTest do
  use ExUnit.Case, async: false

  alias GymIntel.{Membership, MembershipCSV, MembershipImporter, Repo}

  @moduletag :database

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
  end

  defp csv(brands) do
    header = Enum.join(MembershipCSV.headers(), ",")

    rows =
      Enum.map(brands, fn brand ->
        "#{brand},,Synthetic plan,all_uae_branches,,100,1,,,https://example.com,,2026-09-12,TEST ONLY,,,,"
      end)

    Enum.join([header | rows], "\n") <> "\n"
  end

  defp counts do
    memberships = Repo.aggregate(Membership, :count)
    %{rows: [[imports]]} = Repo.query!("SELECT count(*) FROM membership_imports")
    {memberships, imports}
  end

  test "saves all valid rows and one file fingerprint" do
    before = counts()

    assert {:ok, {:imported, %{inserted: 2, skipped: 0}}} =
             MembershipImporter.import_csv(csv(["TEST A", "TEST B"]))

    assert counts() == {elem(before, 0) + 2, elem(before, 1) + 1}
  end

  test "identical file retry does not duplicate rows" do
    contents = csv(["TEST RETRY"])

    assert {:ok, {:imported, %{inserted: 1, skipped: 0}}} =
             MembershipImporter.import_csv(contents)

    after_first_import = counts()
    assert {:ok, :already_imported} = MembershipImporter.import_csv(contents)
    assert counts() == after_first_import
  end

  test "invalid CSV writes neither rows nor fingerprint" do
    before = counts()
    invalid = String.replace(csv(["TEST INVALID"]), ",100,1,", ",100,,")
    assert {:error, {:rows, [_]}} = MembershipImporter.import_csv(invalid)
    assert counts() == before
  end

  test "hardening failures leave both rows and fingerprint unchanged" do
    before = counts()
    valid = csv(["TEST VALID"])
    invalid = csv(["TEST INVALID"])
    [_header, invalid_row] = String.split(invalid, "\n", trim: true)

    for bad <- [
          String.replace(invalid_row, ",100,1,", ",2e2,1,"),
          String.replace(invalid_row, ",100,1,", ",100.001,1,"),
          String.replace(invalid_row, ",100,1,", ",100,2147483648,"),
          String.replace(invalid_row, "2026-09-12", "2099-01-01"),
          String.replace(invalid_row, ",,2026-09-12", ",2026-09-13,2026-09-12"),
          String.replace(invalid_row, "TEST ONLY", "TEST" <> <<0>>),
          String.replace(invalid_row, "example.com", "test-user:test-only@example.com")
        ] do
      assert {:error, {:rows, [%{record: 3}]}} =
               MembershipImporter.import_csv(valid <> bad <> "\n")

      assert counts() == before
    end

    assert {:error, :csv_too_large} =
             MembershipImporter.import_csv(String.duplicate("x", MembershipCSV.max_bytes() + 1))

    assert counts() == before
  end

  test "export-only changes preserve raw fingerprints and skip matching observations" do
    contents = csv(["TEST EXPORT"])
    before = counts()
    exported = <<0xEF, 0xBB, 0xBF>> <> String.replace(contents <> "\n\n", "\n", "\r\n")

    assert {:ok, {:imported, %{inserted: 1, skipped: 0}}} =
             MembershipImporter.import_csv(contents)

    assert {:ok, {:imported, %{inserted: 0, skipped: 1}}} =
             MembershipImporter.import_csv(exported)

    assert {:ok, :already_imported} = MembershipImporter.import_csv(exported)
    assert counts() == {elem(before, 0) + 1, elem(before, 1) + 2}

    fingerprint = :crypto.hash(:sha256, exported) |> Base.encode16(case: :lower)

    assert %{rows: [[1]]} =
             Repo.query!("SELECT row_count FROM membership_imports WHERE content_sha256 = $1", [
               fingerprint
             ])
  end

  test "database failure rolls back earlier rows and fingerprint, allowing a retry" do
    # Test-only constraint; the sandbox also rolls back this schema change.
    Repo.query!("""
    ALTER TABLE memberships ADD CONSTRAINT test_reject_second_row
    CHECK (brand_name <> 'TEST REJECT')
    """)

    before = counts()
    contents = csv(["TEST FIRST", "TEST REJECT"])

    assert_raise Ecto.ConstraintError, fn ->
      MembershipImporter.import_csv(contents)
    end

    assert counts() == before
    Repo.query!("ALTER TABLE memberships DROP CONSTRAINT test_reject_second_row")

    assert {:ok, {:imported, %{inserted: 2, skipped: 0}}} =
             MembershipImporter.import_csv(contents)
  end

  test "overlapping downloads save the shared observation only once" do
    before = counts()

    assert {:ok, {:imported, %{inserted: 2, skipped: 0}}} =
             MembershipImporter.import_csv(csv(["TEST ROW 49", "TEST ROW 50"]))

    assert {:ok, {:imported, %{inserted: 1, skipped: 1}}} =
             MembershipImporter.import_csv(csv(["TEST ROW 50", "TEST ROW 51"]))

    assert counts() == {elem(before, 0) + 3, elem(before, 1) + 2}
  end

  test "repeated rows within one file are skipped" do
    assert {:ok, {:imported, %{inserted: 1, skipped: 1}}} =
             MembershipImporter.import_csv(csv(["TEST REPEATED", "TEST REPEATED"]))
  end

  test "different formatting with equivalent parsed prices does not duplicate rows" do
    contents = csv(["TEST DECIMAL"])

    assert {:ok, {:imported, %{inserted: 1, skipped: 0}}} =
             MembershipImporter.import_csv(contents)

    changed = String.replace(contents, ",100,1,", ",100.00,1,")
    assert {:ok, {:imported, %{inserted: 0, skipped: 1}}} = MembershipImporter.import_csv(changed)
  end

  test "changed source fields remain separate observations" do
    contents = csv(["TEST HISTORY"])

    assert {:ok, {:imported, %{inserted: 1, skipped: 0}}} =
             MembershipImporter.import_csv(contents)

    for changed <- [
          String.replace(contents, "2026-09-12", "2026-09-13"),
          String.replace(contents, ",100,1,", ",120,1,"),
          String.replace(contents, "all_uae_branches", "multiple_named_branches"),
          String.replace(contents, ",TEST ONLY", ",TEST UPDATED NOTE"),
          String.replace(contents, "https://example.com", "https://example.com/new-source"),
          String.replace(contents, ",100,1,,,", ",100,1,,0,")
        ] do
      assert {:ok, {:imported, %{inserted: 1, skipped: 0}}} =
               MembershipImporter.import_csv(changed)
    end
  end

  test "new payment facts are retained and identical classified observations are skipped" do
    contents = csv(["TEST PAYMENT HISTORY"])

    assert {:ok, {:imported, %{inserted: 1, skipped: 0}}} =
             MembershipImporter.import_csv(contents)

    classified = String.replace(contents, "TEST ONLY,,", "TEST ONLY,prepaid_term,non_automatic")

    assert {:ok, {:imported, %{inserted: 1, skipped: 0}}} =
             MembershipImporter.import_csv(classified)

    assert {:ok, {:imported, %{inserted: 0, skipped: 1}}} =
             MembershipImporter.import_csv(String.replace(classified, ",100,1,", ",100.00,1,"))

    changed = String.replace(classified, "non_automatic", "automatic")
    assert {:ok, {:imported, %{inserted: 1, skipped: 0}}} = MembershipImporter.import_csv(changed)
    changed = String.replace(classified, "prepaid_term", "recurring")
    assert {:ok, {:imported, %{inserted: 1, skipped: 0}}} = MembershipImporter.import_csv(changed)
  end

  test "legacy and new blank headers describe the same observation" do
    current = csv(["TEST LEGACY DEDUPE"])
    [header, row] = String.split(current, "\n", trim: true)
    legacy_header = header |> String.split(",") |> Enum.take(13) |> Enum.join(",")
    legacy_row = row |> String.split(",") |> Enum.take(13) |> Enum.join(",")
    legacy = legacy_header <> "\n" <> legacy_row <> "\n"

    assert {:ok, {:imported, %{inserted: 1, skipped: 0}}} = MembershipImporter.import_csv(legacy)
    assert {:ok, {:imported, %{inserted: 0, skipped: 1}}} = MembershipImporter.import_csv(current)
  end

  test "database constraints reject unknown payment codes even when bypassing changesets" do
    for {column, constraint} <- [
          {"payment_structure", "memberships_payment_structure_allowed"},
          {"renewal_policy", "memberships_renewal_policy_allowed"}
        ] do
      error =
        assert_raise Postgrex.Error, fn ->
          Repo.query!(
            """
            INSERT INTO memberships
              (brand_name, plan_name, access_scope, advertised_price_aed, billing_period_months,
               source_url, observed_on, inserted_at, updated_at, #{column})
            VALUES ('TEST CONSTRAINT', 'TEST ONLY', 'all_uae_branches', 100, 1,
              'https://example.com', '2026-09-12', now(), now(), 'guessed')
            """,
            [],
            mode: :savepoint
          )
        end

      assert error.postgres.constraint == constraint
    end
  end

  test "VAT/admin changes are retained but numerically equivalent fees are deduplicated" do
    original = csv(["TEST VAT HISTORY"])

    assert {:ok, {:imported, %{inserted: 1, skipped: 0}}} =
             MembershipImporter.import_csv(original)

    classified = String.replace(original, "TEST ONLY,,,,", "TEST ONLY,,,included,30")

    assert {:ok, {:imported, %{inserted: 1, skipped: 0}}} =
             MembershipImporter.import_csv(classified)

    assert {:ok, {:imported, %{inserted: 0, skipped: 1}}} =
             MembershipImporter.import_csv(
               String.replace(classified, "included,30", "included,30.00")
             )

    for changed <- [
          String.replace(classified, "included", "excluded"),
          String.replace(classified, "included,30", "included,0")
        ] do
      assert {:ok, {:imported, %{inserted: 1, skipped: 0}}} =
               MembershipImporter.import_csv(changed)
    end
  end

  test "15-column payment snapshots and 17-column blank extensions deduplicate" do
    contents = csv(["TEST VAT LEGACY"])
    records = NimbleCSV.RFC4180.parse_string(contents, skip_headers: false)

    legacy =
      records
      |> Enum.map(&Enum.take(&1, 15))
      |> NimbleCSV.RFC4180.dump_to_iodata()
      |> IO.iodata_to_binary()

    assert {:ok, {:imported, %{inserted: 1, skipped: 0}}} = MembershipImporter.import_csv(legacy)

    assert {:ok, {:imported, %{inserted: 0, skipped: 1}}} =
             MembershipImporter.import_csv(contents)
  end

  test "database enforces VAT allowlist and nonnegative admin fee without a changeset" do
    for {column, value, constraint} <- [
          {"price_vat_status", "'assumed'", "memberships_price_vat_status_allowed"},
          {"admin_fee_aed", "-1", "memberships_admin_fee_non_negative"}
        ] do
      error =
        assert_raise Postgrex.Error, fn ->
          Repo.query!(
            """
            INSERT INTO memberships
              (brand_name, plan_name, access_scope, advertised_price_aed, billing_period_months,
               source_url, observed_on, inserted_at, updated_at, #{column})
            VALUES ('TEST VAT CONSTRAINT', 'TEST ONLY', 'all_uae_branches', 100, 1,
              'https://example.com', '2026-09-12', now(), now(), #{value})
            """,
            [],
            mode: :savepoint
          )
        end

      assert error.postgres.constraint == constraint
    end
  end
end
