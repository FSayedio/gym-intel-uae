defmodule GymIntel.SourceMonitor do
  @moduledoc "Internal weekly change reports. Never imports data or advances membership observation dates."
  import Ecto.Query
  alias GymIntel.{Repo, SourceMonitor.Content, SourceMonitor.Fetcher, SourceMonitor.Sources}

  @worker "GymIntel.Workers.CheckSources"

  def check(opts \\ []) do
    fetch = Keyword.get(opts, :fetch, &Fetcher.fetch/1)
    sources = Keyword.get(opts, :sources, Sources.all())
    now = Keyword.get(opts, :now, DateTime.utc_now())
    job_id = Keyword.get(opts, :job_id)

    # Keep two terminal monitor jobs. A normal running job will become the
    # newest terminal job after returning; reserve its slot when it exists.
    retain = if is_integer(job_id), do: 1, else: 2

    Repo.query!(
      """
      DELETE FROM oban_jobs WHERE worker = $1 AND queue = 'source_checks'
        AND state IN ('completed', 'cancelled', 'discarded') AND id NOT IN (
          SELECT id FROM oban_jobs WHERE worker = $1 AND queue = 'source_checks'
          AND state IN ('completed', 'cancelled', 'discarded')
          ORDER BY COALESCE(completed_at, cancelled_at, discarded_at, inserted_at) DESC, id DESC
          LIMIT $2)
      """,
      [@worker, retain]
    )

    Repo.transaction(
      fn ->
        # Serialises even manual executions and multiple app replicas. Network reads
        # are bounded, and no membership tables are locked or written by this job.
        case Repo.query!("SELECT pg_try_advisory_xact_lock(72401926)").rows do
          [[false]] -> Repo.rollback(:check_already_running)
          [[true]] -> :ok
        end

        results = Enum.map(sources, &check_source(&1, fetch, now))

        report = %{
          "checked_at" => DateTime.to_iso8601(now),
          "sources" => results,
          "meaning" => "Page checks only. No offer facts or observation dates were updated."
        }

        Repo.insert_all("source_check_reports", [%{checked_at: now, report: report}])

        Repo.query!("""
        DELETE FROM source_check_reports WHERE id NOT IN
          (SELECT id FROM source_check_reports ORDER BY id DESC LIMIT 2)
        """)

        report
      end,
      timeout: 240_000
    )
  end

  def reports do
    Repo.all(from(r in "source_check_reports", order_by: [desc: r.id], select: r.report))
  end

  def states do
    Repo.all(
      from(s in "source_check_states",
        order_by: s.source_id,
        select: %{
          source_id: s.source_id,
          checked_at: s.checked_at,
          hash: s.content_hash,
          accepted_hash: s.accepted_hash
        }
      )
    )
  end

  @doc "Acknowledge a page baseline only after manual review; not a membership verification."
  def acknowledge(source_id, expected_hash) do
    case Repo.transaction(fn ->
           case Repo.query!("SELECT pg_try_advisory_xact_lock(72401926)").rows do
             [[false]] -> Repo.rollback(:check_already_running)
             [[true]] -> :ok
           end

           case Repo.query!(
                  """
                  UPDATE source_check_states SET accepted_hash = content_hash, accepted_text = content_text
                  WHERE source_id = $1 AND content_hash = $2
                  """,
                  [source_id, expected_hash]
                ).num_rows do
             1 -> :ok
             _ -> Repo.rollback(:baseline_changed_or_missing)
           end
         end) do
      {:ok, :ok} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp check_source(source, fetch, now) do
    previous =
      Repo.one(
        from(s in "source_check_states",
          where: s.source_id == ^source.id,
          select: %{
            hash: s.content_hash,
            text: s.content_text,
            accepted_hash: s.accepted_hash,
            accepted_text: s.accepted_text
          }
        )
      )

    common = %{
      "source" => source.id,
      "gym" => source.gym,
      "label" => source.label,
      "url" => source.url,
      "fetch_mode" => if(source.url == Sources.rendered_url(), do: "browser", else: "http"),
      "coverage" => source.coverage,
      "offer_verified" => false
    }

    with {:ok, html} <- fetch.(source.url), {:ok, current} <- Content.extract(html, source) do
      accepted = if previous, do: previous.accepted_hash

      Repo.insert_all(
        "source_check_states",
        [
          %{
            source_id: source.id,
            content_hash: current.hash,
            content_text: current.text,
            accepted_hash: accepted,
            accepted_text: if(previous, do: previous.accepted_text),
            checked_at: now
          }
        ],
        on_conflict: {:replace, [:content_hash, :content_text, :checked_at]},
        conflict_target: [:source_id]
      )

      Map.merge(common, %{
        "status" => Content.classify(previous, current),
        "review_required" => accepted != current.hash,
        "hash" => current.hash,
        "previous_hash" => if(previous, do: previous.hash),
        "change_excerpt" => excerpt(accepted_baseline(previous), current)
      })
    else
      {:error, reason} ->
        # A failure must not erase a good comparison baseline, even after two failures.
        Map.merge(common, %{
          "status" => "check_failed",
          "review_required" => true,
          "reason" => reason_text(reason)
        })
    end
  end

  defp accepted_baseline(%{accepted_hash: hash, accepted_text: text}) when is_binary(hash),
    do: %{hash: hash, text: text}

  defp accepted_baseline(_), do: nil

  defp excerpt(nil, current),
    do: %{"before" => nil, "after" => String.slice(current.text, 0, 240)}

  defp excerpt(%{hash: hash}, %{hash: hash}), do: nil

  defp excerpt(previous, current) do
    old = String.graphemes(previous.text)
    new = String.graphemes(current.text)
    prefix = Enum.zip(old, new) |> Enum.take_while(fn {a, b} -> a == b end) |> length()
    start = max(prefix - 60, 0)

    %{
      "before" => String.slice(previous.text, start, 240),
      "after" => String.slice(current.text, start, 240)
    }
  end

  defp reason_text({:http_status, code}), do: "HTTP #{code}; redirects are not followed"
  defp reason_text({:browser, reason}) when is_binary(reason), do: reason
  defp reason_text(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp reason_text(_), do: "source_check_failed"
end
