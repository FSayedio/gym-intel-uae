defmodule GymIntel.MembershipImporter do
  @moduledoc "Atomically imports small CSV files, skipping identical files and matching source rows."

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
    |> Multi.run(:lock, fn repo, _ ->
      # Serialize membership writes during the check-and-insert sequence.
      # PostgreSQL releases this lock at transaction end, including rollback.
      repo.query!("LOCK TABLE memberships IN SHARE ROW EXCLUSIVE MODE")
      {:ok, :locked}
    end)
    |> Multi.insert_all(:claim, "membership_imports", [marker],
      on_conflict: :nothing,
      conflict_target: [:content_sha256]
    )
    |> Multi.run(:result, fn repo, %{claim: {count, _}} ->
      if count == 0 do
        {:ok, :already_imported}
      else
        # Any failed insert aborts the transaction, including the fingerprint.
        totals =
          Enum.reduce(memberships, %{inserted: 0, skipped: 0}, fn membership, totals ->
            if repo.exists?(matching_observation(membership)) do
              Map.update!(totals, :skipped, &(&1 + 1))
            else
              repo.insert!(membership)
              Map.update!(totals, :inserted, &(&1 + 1))
            end
          end)

        {:ok, {:imported, totals}}
      end
    end)
    |> Repo.transaction()
    |> case do
      {:ok, %{result: result}} -> {:ok, result}
      {:error, step, reason, _changes} -> {:error, {step, reason}}
    end
  end

  defp matching_observation(membership) do
    filters =
      Enum.reduce(Membership.source_fields(), dynamic(true), fn name, filters ->
        case Map.fetch!(membership, name) do
          nil -> dynamic([m], ^filters and is_nil(field(m, ^name)))
          value -> dynamic([m], ^filters and field(m, ^name) == ^value)
        end
      end)

    from(m in Membership, where: ^filters)
  end
end
