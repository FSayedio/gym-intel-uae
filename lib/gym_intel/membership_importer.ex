defmodule GymIntel.MembershipImporter do
  @moduledoc "Atomically imports observations and internal note versions using database uniqueness."

  import Ecto.Query

  alias Ecto.Multi
  alias GymIntel.{Membership, MembershipCSV, Repo}

  def import_file(path) do
    with {:ok, contents} <- MembershipCSV.read_contents(path), do: import_csv(contents)
  end

  def import_csv(contents) do
    case MembershipCSV.parse(contents) do
      {:ok, []} -> {:ok, :empty}
      {:ok, memberships} -> save(contents, memberships)
      {:error, reason} -> {:error, reason}
    end
  end

  defp save(contents, memberships) do
    fingerprint = :crypto.hash(:sha256, contents) |> Base.encode16(case: :lower)

    marker = %{
      content_sha256: fingerprint,
      row_count: length(memberships),
      inserted_at: DateTime.utc_now()
    }

    Multi.new()
    |> Multi.insert_all(:claim, "membership_imports", [marker],
      on_conflict: :nothing,
      conflict_target: [:content_sha256]
    )
    |> Multi.run(:result, fn repo, %{claim: {count, _}} ->
      if count == 0 do
        {:ok, :already_imported}
      else
        # A shared write order avoids opposite-order batches deadlocking on
        # overlapping observation/note keys. No table-wide lock or UPDATE.
        with {:ok, keyed} <- with_database_keys(memberships, repo),
             {:ok, totals} <- import_rows(keyed, repo, fingerprint) do
          {:ok, {:imported, totals}}
        end
      end
    end)
    |> Repo.transaction()
    |> case do
      {:ok, %{result: result}} -> {:ok, result}
      {:error, step, reason, _changes} -> {:error, {step, reason}}
    end
  end

  defp import_rows(keyed, repo, fingerprint) do
    keyed
    |> Enum.sort_by(fn {membership, key} -> {key, membership.notes || ""} end)
    |> Enum.reduce_while({:ok, %{inserted: 0, skipped: 0, notes_added: 0}}, fn
      {membership, key}, {:ok, totals} ->
        with {:ok, id, inserted} <- insert_observation(repo, membership, key, fingerprint),
             {:ok, notes_added} <- insert_note(repo, id, membership.notes, fingerprint) do
          # The trigger also captures initial notes for writers outside this importer.
          initial_note = if inserted == 1 and not is_nil(membership.notes), do: 1, else: 0

          updated =
            totals
            |> Map.update!(:inserted, &(&1 + inserted))
            |> Map.update!(:skipped, &(&1 + 1 - inserted))
            |> Map.update!(:notes_added, &(&1 + initial_note + notes_added))

          {:cont, {:ok, updated}}
        else
          {:error, reason} -> {:halt, {:error, reason}}
        end
    end)
  end

  defp with_database_keys(memberships, repo) do
    types =
      ~w(text text text text text numeric integer integer numeric text date date text text text numeric)

    fields = Membership.identity_fields()

    arguments =
      Enum.zip(fields, types)
      |> Enum.map_join(", ", fn {field, type} -> "(item.attrs->>'#{field}')::#{type}" end)

    payload =
      Enum.map(memberships, fn membership ->
        Map.new(fields, fn field -> {field, json_value(Map.fetch!(membership, field))} end)
      end)

    result =
      repo.query!(
        """
        SELECT public.membership_observation_key_v1(#{arguments})
        FROM jsonb_array_elements($1::jsonb) WITH ORDINALITY AS item(attrs, position)
        ORDER BY item.position
        """,
        [payload]
      )

    if length(result.rows) == length(memberships) do
      {:ok, Enum.zip(memberships, Enum.map(result.rows, fn [key] -> key end))}
    else
      {:error, :observation_key_count_mismatch}
    end
  end

  defp json_value(%Decimal{} = value), do: Decimal.to_string(value, :normal)
  defp json_value(%Date{} = value), do: Date.to_iso8601(value)
  defp json_value(value), do: value

  defp insert_observation(repo, membership, key, fingerprint) do
    now = DateTime.utc_now()

    entry = membership |> Map.from_struct() |> Map.take(Membership.source_fields())

    entry =
      Map.merge(entry, %{inserted_at: now, updated_at: now, first_import_sha256: fingerprint})

    case repo.insert_all(Membership, [entry],
           on_conflict: :nothing,
           conflict_target: [:observation_key],
           returning: [:id, :observation_key]
         ) do
      {1, [inserted]} ->
        if inserted.observation_key == key,
          do: {:ok, inserted.id, 1},
          else: {:error, :observation_key_mismatch}

      {0, []} ->
        # This is a separate statement/snapshot after ON CONFLICT has waited
        # for a concurrent writer. Compare actual fields too: a key collision
        # must fail visibly, never skip different facts as though identical.
        case repo.one(
               from(m in matching_observation(membership),
                 where: m.observation_key == ^key,
                 select: m.id
               )
             ) do
          nil -> {:error, :observation_key_mismatch}
          id -> {:ok, id, 0}
        end
    end
  end

  defp insert_note(_repo, _id, nil, _fingerprint), do: {:ok, 0}

  defp insert_note(repo, id, notes, fingerprint) do
    entry = %{
      membership_id: id,
      notes: notes,
      recorded_at: DateTime.utc_now(),
      source_import_sha256: fingerprint
    }

    case repo.insert_all("membership_notes", [entry],
           on_conflict: :nothing,
           conflict_target: [:membership_id, :note_key]
         ) do
      {1, _} ->
        {:ok, 1}

      {0, _} ->
        if repo.exists?(
             from(n in "membership_notes",
               where: n.membership_id == ^id and n.notes == ^notes
             )
           ) do
          {:ok, 0}
        else
          {:error, :note_key_mismatch}
        end
    end
  end

  defp matching_observation(membership) do
    filters =
      Enum.reduce(Membership.identity_fields(), dynamic(true), fn name, filters ->
        case Map.fetch!(membership, name) do
          nil -> dynamic([m], ^filters and is_nil(field(m, ^name)))
          value -> dynamic([m], ^filters and field(m, ^name) == ^value)
        end
      end)

    from(m in Membership, where: ^filters)
  end
end
