defmodule GymIntel.ObservationMigrationDatabaseTest do
  use ExUnit.Case, async: false
  alias GymIntel.Repo
  @moduletag :database
  @schema "feature5_upgrade_test"

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    Repo.query!("CREATE SCHEMA #{@schema}")

    Repo.query!(
      "CREATE TABLE #{@schema}.membership_imports (LIKE public.membership_imports INCLUDING ALL)"
    )

    Repo.query!(
      "CREATE TABLE #{@schema}.memberships (LIKE public.memberships INCLUDING DEFAULTS INCLUDING CONSTRAINTS)"
    )

    Repo.query!(
      "ALTER TABLE #{@schema}.memberships DROP COLUMN observation_key, DROP COLUMN first_import_sha256"
    )

    Repo.query!("ALTER TABLE #{@schema}.memberships ADD PRIMARY KEY(id)")
    :ok
  end

  defp seed(id, note) do
    Repo.query!(
      """
      INSERT INTO #{@schema}.memberships
        (id,brand_name,plan_name,access_scope,advertised_price_aed,billing_period_months,
         source_url,observed_on,notes,inserted_at,updated_at)
      VALUES ($1,'TEST UPGRADE','TEST ONLY','all_uae_branches',199.00,1,
        'https://example.com/upgrade','2026-10-22',$2,'2026-10-22 10:00:00','2026-10-22 10:00:00')
      """,
      [id, note]
    )
  end

  defp apply_upgrade do
    for statement <-
          String.split(File.read!("priv/observation_integrity.sql"), "\n-- statement\n",
            trim: true
          ) do
      Repo.query!(String.replace(statement, "public.", "#{@schema}."))
    end
  end

  test "upgrading old rows preserves all original columns and copies notes with honest provenance" do
    note = "Original Arabic ملاحظات\nDo not erase"
    seed(42, note)
    before = Repo.query!("SELECT to_jsonb(m) FROM #{@schema}.memberships m ORDER BY id").rows
    apply_upgrade()

    after_rows =
      Repo.query!(
        "SELECT to_jsonb(m) - ARRAY['observation_key','first_import_sha256'] FROM #{@schema}.memberships m ORDER BY id"
      ).rows

    assert after_rows == before

    assert %{rows: [[42, ^note, nil, _recorded_at]]} =
             Repo.query!(
               "SELECT membership_id,notes,source_import_sha256,recorded_at FROM #{@schema}.membership_notes"
             )

    assert %{rows: [[32]]} =
             Repo.query!("SELECT octet_length(observation_key) FROM #{@schema}.memberships")

    assert %{rows: [[1]]} = Repo.query!("SELECT count(*) FROM #{@schema}.dashboard_memberships")
  end

  test "note-only conflicts stop migration and roll back its schema changes without deleting data" do
    seed(42, "First evidence")
    seed(43, "Different evidence")
    before = Repo.query!("SELECT to_jsonb(m) FROM #{@schema}.memberships m ORDER BY id").rows
    error = assert_raise Postgrex.Error, fn -> Repo.transaction(fn -> apply_upgrade() end) end
    assert error.postgres.code == :unique_violation
    assert error.postgres.message =~ "without deleting or consolidating"

    assert Repo.query!("SELECT to_jsonb(m) FROM #{@schema}.memberships m ORDER BY id").rows ==
             before

    assert %{rows: [[nil]]} = Repo.query!("SELECT to_regclass('#{@schema}.membership_notes')")

    assert %{rows: [[0]]} =
             Repo.query!(
               "SELECT count(*) FROM information_schema.columns WHERE table_schema = '#{@schema}' AND table_name='memberships' AND column_name='observation_key'"
             )
  end

  test "automatic down refuses to discard note history" do
    Code.require_file("priv/repo/migrations/20261023000100_enforce_observation_integrity.exs")

    assert_raise Ecto.MigrationError, ~r/would discard note history/, fn ->
      apply(
        Module.concat(["GymIntel", "Repo", "Migrations", "EnforceObservationIntegrity"]),
        :down,
        []
      )
    end
  end
end
