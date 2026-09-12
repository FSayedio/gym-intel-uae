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
        "#{brand},,Synthetic plan,all_uae_branches,,100,1,,,https://example.com,,2026-09-12,TEST ONLY"
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
end
