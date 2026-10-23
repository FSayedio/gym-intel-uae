defmodule GymIntel.RecoverySnapshotDatabaseTest do
  use ExUnit.Case, async: false

  alias GymIntel.Repo
  @moduletag :database

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
  end

  test "snapshot recognizes equivalent array casts without hiding changed constraint semantics" do
    sql = File.read!("scripts/recovery/snapshot.sql")
    [_prefix, rest] = String.split(sql, "regexp_replace(regexp_replace(regexp_replace(", parts: 2)
    [body, _suffix] = String.split(rest, "\n    ELSE", parts: 2)

    expression =
      ("regexp_replace(regexp_replace(regexp_replace(" <> body)
      |> String.replace("pg_get_constraintdef(x.oid, false)", "$1::text")

    normalize = fn definition ->
      %{rows: [[value]]} = Repo.query!("SELECT " <> expression, [definition])
      value
    end

    source =
      "CHECK (((access_scope)::text = ANY ((ARRAY['single_branch'::character varying, 'all_uae_branches'::character varying])::text[])))"

    restored =
      "CHECK (((access_scope)::text = ANY (ARRAY[('single_branch'::character varying)::text, ('all_uae_branches'::character varying)::text])))"

    assert normalize.(source) == normalize.(restored)
    refute normalize.(source) == normalize.(String.replace(restored, "single_branch", "made_up"))
    refute normalize.(source) == normalize.(String.replace(restored, " = ANY", " <> ANY"))
    refute normalize.(source) == normalize.(restored <> " OR true")
    unrelated = "CHECK (((price)::numeric(10, 2)) > 0)"
    assert normalize.(unrelated) == unrelated
  end
end
