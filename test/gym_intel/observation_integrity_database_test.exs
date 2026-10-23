defmodule GymIntel.ObservationIntegrityDatabaseTest do
  use ExUnit.Case, async: false
  import Ecto.Query
  alias GymIntel.{Membership, MembershipCSV, MembershipImporter, Repo}
  @moduletag :database

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
  end

  defp attrs(changes \\ %{}) do
    Map.merge(
      %{
        brand_name: "TEST INTEGRITY",
        plan_name: "TEST ONLY",
        access_scope: "all_uae_branches",
        advertised_price_aed: Decimal.new("199.00"),
        billing_period_months: 1,
        source_url: "https://example.com/integrity",
        observed_on: ~D[2026-10-22],
        notes: "Original synthetic note"
      },
      changes
    )
  end

  defp insert(changes \\ %{}), do: Repo.insert!(struct(Membership, attrs(changes)))

  defp csv(brand, note) do
    values = attrs(%{brand_name: brand, notes: note})

    cells =
      Enum.map(Membership.source_fields(), fn field ->
        case Map.get(values, field) do
          nil -> ""
          %Decimal{} = value -> Decimal.to_string(value, :normal)
          %Date{} = value -> Date.to_iso8601(value)
          value -> to_string(value)
        end
      end)

    [MembershipCSV.headers(), cells]
    |> NimbleCSV.RFC4180.dump_to_iodata()
    |> IO.iodata_to_binary()
  end

  defp denied(sql) do
    error = assert_raise Postgrex.Error, fn -> Repo.query!(sql, [], mode: :savepoint) end
    assert error.postgres.code == :insufficient_privilege
  end

  test "the database generates the key and direct SQL cannot insert a duplicate or supply its own key" do
    row = insert()
    assert byte_size(row.observation_key) == 32
    assert Membership.identity_fields() == Membership.source_fields() -- [:notes]
    assert length(Membership.identity_fields()) == 16

    columns = [:notes | Membership.identity_fields()] ++ [:inserted_at, :updated_at]
    names = Enum.map_join(columns, ",", &Atom.to_string/1)

    error =
      assert_raise Postgrex.Error, fn ->
        Repo.query!(
          "INSERT INTO memberships (#{names}) SELECT #{names} FROM memberships WHERE id = $1",
          [row.id],
          mode: :savepoint
        )
      end

    assert error.postgres.code == :unique_violation

    error =
      assert_raise Postgrex.Error, fn ->
        Repo.query!(
          "UPDATE memberships SET observation_key = decode('01','hex') WHERE id = $1",
          [row.id],
          mode: :savepoint
        )
      end

    assert error.postgres.code == :generated_always
    assert Repo.aggregate(Membership, :count) == 1
  end

  test "only notes are excluded; every other source field can distinguish observations" do
    original = insert()

    changes = [
      %{brand_name: "TEST OTHER"},
      %{branch_name: "TEST BRANCH"},
      %{plan_name: "TEST PLAN"},
      %{access_scope: "multiple_named_branches"},
      %{offer_type: "standard"},
      %{advertised_price_aed: Decimal.new("219")},
      %{billing_period_months: 2},
      %{minimum_commitment_months: 0},
      %{joining_fee_aed: Decimal.new("0")},
      %{source_url: "https://example.com/other"},
      %{source_published_on: ~D[2026-10-21]},
      %{observed_on: ~D[2026-10-21]},
      %{payment_structure: "recurring"},
      %{renewal_policy: "automatic"},
      %{price_vat_status: "included"},
      %{admin_fee_aed: Decimal.new("0")}
    ]

    keys = Enum.map(changes, fn change -> insert(change).observation_key end)
    assert MapSet.size(MapSet.new([original.observation_key | keys])) == 17
  end

  test "database numeric equivalence, nulls and field boundaries are canonical" do
    original = insert()
    fields = Enum.map_join(Membership.identity_fields(), ",", &Atom.to_string/1)

    assert %{rows: [[true]]} =
             Repo.query!(
               "SELECT observation_key = public.membership_observation_key_v1(#{fields}) FROM memberships WHERE id = $1",
               [original.id]
             )

    Repo.query!("SET LOCAL DateStyle = 'SQL, DMY'")
    Repo.query!("SET LOCAL TimeZone = 'Pacific/Honolulu'")

    assert %{rows: [[true]]} =
             Repo.query!(
               "SELECT observation_key = public.membership_observation_key_v1(#{fields}) FROM memberships WHERE id = $1",
               [original.id]
             )

    assert {:ok, {:imported, %{inserted: 0, skipped: 1, notes_added: 0}}} =
             MembershipImporter.import_csv(
               csv("TEST INTEGRITY", "Original synthetic note")
               |> String.replace(",199.00,", ",199,")
             )

    # Concatenation without field boundaries would confuse these two pairs.
    left = insert(%{brand_name: "A|B", plan_name: "C"})
    right = insert(%{brand_name: "A", plan_name: "B|C"})
    refute left.observation_key == right.observation_key

    assert insert(%{joining_fee_aed: Decimal.new("0")}).observation_key !=
             original.observation_key
  end

  test "direct inserts capture initial notes and blank notes create no version" do
    row = insert()

    assert %{rows: [["Original synthetic note", nil]]} =
             Repo.query!(
               "SELECT notes,source_import_sha256 FROM membership_notes WHERE membership_id = $1",
               [row.id]
             )

    without_note = insert(%{brand_name: "TEST NO NOTE", notes: nil})
    refute Repo.exists?(from(n in "membership_notes", where: n.membership_id == ^without_note.id))
  end

  test "note-only edits preserve row ID and original text, and repeated versions add nothing" do
    original = csv("TEST NOTE HISTORY", "Towel inlcuded")
    correction = csv("TEST NOTE HISTORY", "Towel included")

    assert {:ok, {:imported, %{inserted: 1, skipped: 0, notes_added: 1}}} =
             MembershipImporter.import_csv(original)

    row = Repo.get_by!(Membership, brand_name: "TEST NOTE HISTORY")

    assert {:ok, {:imported, %{inserted: 0, skipped: 1, notes_added: 1}}} =
             MembershipImporter.import_csv(correction)

    assert {:ok, {:imported, %{inserted: 0, skipped: 1, notes_added: 0}}} =
             MembershipImporter.import_csv(correction <> "\n")

    assert Repo.get!(Membership, row.id).notes == "Towel inlcuded"
    assert Repo.get_by!(Membership, brand_name: "TEST NOTE HISTORY").id == row.id

    assert %{rows: notes} =
             Repo.query!(
               "SELECT notes FROM membership_notes WHERE membership_id = $1 ORDER BY id",
               [row.id]
             )

    assert notes == [["Towel inlcuded"], ["Towel included"]]

    assert %{rows: [[2]]} =
             Repo.query!(
               "SELECT count(*) FROM membership_notes WHERE membership_id = $1 AND source_import_sha256 IS NOT NULL",
               [row.id]
             )

    # Unknown notes neither erase evidence nor create a fabricated blank version.
    assert {:ok, {:imported, %{inserted: 0, skipped: 1, notes_added: 0}}} =
             MembershipImporter.import_csv(csv("TEST NOTE HISTORY", ""))
  end

  test "a failed new note rolls back all changes from that file, not earlier history" do
    assert {:ok, _} = MembershipImporter.import_csv(csv("TEST PRIOR", "Prior evidence"))
    before = business_counts()

    Repo.query!(
      "ALTER TABLE membership_notes ADD CONSTRAINT test_reject_note CHECK (notes <> 'TEST REJECT')"
    )

    [header, first] = String.split(csv("TEST NEW", "Valid evidence"), "\n", trim: true)
    [_header, second] = String.split(csv("TEST PRIOR", "TEST REJECT"), "\n", trim: true)

    assert_raise Postgrex.Error, fn ->
      MembershipImporter.import_csv(Enum.join([header, first, second], "\n"))
    end

    assert business_counts() == before
    Repo.query!("ALTER TABLE membership_notes DROP CONSTRAINT test_reject_note")
  end

  test "a simulated observation-key collision fails rather than skipping different facts" do
    [definition | _] =
      String.split(File.read!("priv/observation_integrity.sql"), "\n-- statement\n", trim: true)

    constant =
      definition
      |> String.replace("CREATE FUNCTION", "CREATE OR REPLACE FUNCTION")
      |> then(
        &Regex.replace(~r/AS \$\$.*\$\$;/s, &1, "AS $$ SELECT decode(repeat('00',32),'hex') $$;")
      )

    Repo.query!(constant)
    [header, first] = String.split(csv("TEST COLLISION A", "TEST"), "\n", trim: true)
    [_header, second] = String.split(csv("TEST COLLISION B", "TEST"), "\n", trim: true)

    assert {:error, {:result, :observation_key_mismatch}} =
             MembershipImporter.import_csv(Enum.join([header, first, second], "\n"))

    assert business_counts() == {0, 0, 0}
  end

  test "a simulated note-key collision preserves earlier evidence and rejects the new file" do
    Repo.query!("""
    CREATE OR REPLACE FUNCTION public.membership_note_key_v1(note_text text) RETURNS bytea
    LANGUAGE sql IMMUTABLE STRICT PARALLEL SAFE SET search_path=pg_catalog
    AS $$ SELECT decode(repeat('00',32),'hex') $$
    """)

    assert {:ok, _} = MembershipImporter.import_csv(csv("TEST NOTE COLLISION", "First note"))
    before = business_counts()

    assert {:error, {:result, :note_key_mismatch}} =
             MembershipImporter.import_csv(csv("TEST NOTE COLLISION", "Different note"))

    assert business_counts() == before
    assert %{rows: [["First note"]]} = Repo.query!("SELECT notes FROM membership_notes")
  end

  test "the actual permission function grants append-only runtime and public-view-only reader access" do
    suffix = System.unique_integer([:positive])
    runtime = "feature5_app_#{suffix}"
    reader = "feature5_reader_#{suffix}"
    for role <- [runtime, reader], do: Repo.query!("CREATE ROLE #{role} NOLOGIN NOINHERIT")

    Repo.query!("SELECT public.configure_observation_access($1::name,$2::name)", [runtime, reader])

    try do
      Repo.query!("SET LOCAL ROLE #{runtime}")

      assert {:ok, {:imported, %{inserted: 1, notes_added: 1}}} =
               MembershipImporter.import_csv(csv("TEST RUNTIME", "Internal evidence"))

      for sql <- [
            "UPDATE memberships SET notes = notes WHERE false",
            "DELETE FROM memberships WHERE false",
            "UPDATE membership_notes SET notes = notes WHERE false",
            "DELETE FROM membership_notes WHERE false",
            "SELECT public.configure_observation_access(NULL::name,NULL::name)"
          ] do
        denied(sql)
      end

      Repo.query!("RESET ROLE")
      Repo.query!("SET LOCAL ROLE #{reader}")
      result = Repo.query!("SELECT * FROM dashboard_memberships")
      assert length(result.rows) == 1
      assert length(result.columns) == 16
      refute "notes" in result.columns
      refute "observation_key" in result.columns

      for sql <- [
            "SELECT notes FROM memberships LIMIT 0",
            "SELECT * FROM membership_notes LIMIT 0",
            "SELECT * FROM membership_imports LIMIT 0",
            "SELECT * FROM oban_jobs LIMIT 0",
            "DELETE FROM dashboard_memberships WHERE false"
          ] do
        denied(sql)
      end
    after
      Repo.query!("RESET ROLE")
    end
  end

  defp business_counts do
    %{rows: [[rows, notes, imports]]} =
      Repo.query!(
        "SELECT (SELECT count(*) FROM memberships),(SELECT count(*) FROM membership_notes),(SELECT count(*) FROM membership_imports)"
      )

    {rows, notes, imports}
  end
end
