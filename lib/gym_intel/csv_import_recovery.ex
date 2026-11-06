defmodule GymIntel.CSVImportRecovery do
  @moduledoc "Coordinates CSV attempts with job-row locks; never infers ownership from age alone."

  import Ecto.Query
  alias GymIntel.{Repo, Workers.ImportMemberships}

  @execution_limit 120_000
  @transaction_limit 110_000
  @rescue_after 180
  @version_key "csv_recovery_version"

  def execution_limit, do: @execution_limit
  def rescue_after, do: @rescue_after
  def version_key, do: @version_key

  @doc "Run writes only while this saved attempt is still executing and locked."
  def with_attempt(%Oban.Job{} = job, fun) when is_function(fun, 0) do
    Repo.transaction(
      fn ->
        # PostgreSQL, rather than a separate heartbeat connection, bounds the
        # transaction even if the entire BEAM is suspended. All values are fixed.
        # A nonzero -> nonzero SET doesn't rearm an existing timer. Reset at
        # this boundary so an inherited session setting cannot extend our budget.
        Repo.query!("SET LOCAL transaction_timeout = '0'", [], log: false)
        Repo.query!("SET LOCAL transaction_timeout = '110s'", [], log: false)
        Repo.query!("SET LOCAL statement_timeout = '30s'", [], log: false)
        Repo.query!("SET LOCAL idle_in_transaction_session_timeout = '30s'", [], log: false)
        Repo.query!("SET LOCAL lock_timeout = '1s'", [], log: false)

        current = Repo.one(from(j in Oban.Job, where: j.id == ^job.id, lock: "FOR UPDATE"))

        if same_attempt?(current, job) do
          case fun.() do
            {:ok, _} = result -> result
            result -> Repo.rollback(result)
          end
        else
          Repo.rollback({:cancel, :stale_attempt})
        end
      end,
      timeout: @transaction_limit
    )
    |> case do
      {:ok, result} -> result
      {:error, result} -> result
    end
  end

  defp same_attempt?(%Oban.Job{} = current, job) do
    current.state == "executing" and current.worker == inspect(ImportMemberships) and
      current.queue == "imports" and current.attempt == job.attempt and
      current.attempted_at == job.attempted_at and current.args == job.args
  end

  defp same_attempt?(_, _), do: false

  @doc "Rescue at most 50 marked CSV jobs, skipping rows owned by another transaction."
  def sweep(now \\ DateTime.utc_now()) do
    cutoff = DateTime.add(now, -@rescue_after, :second)

    Repo.transaction(fn ->
      # This lock is acquired before changing state. A worker paused before
      # acquiring it is fenced by with_attempt when it eventually resumes.
      jobs =
        Repo.all(
          from(j in Oban.Job,
            where:
              j.worker == ^inspect(ImportMemberships) and j.queue == "imports" and
                j.state == "executing" and j.attempt > 0 and j.attempted_at < ^cutoff and
                fragment("?->>? = '1'", j.meta, ^@version_key),
            order_by: [asc: j.attempted_at, asc: j.id],
            limit: 50,
            lock: "FOR UPDATE SKIP LOCKED"
          )
        )

      Enum.reduce(jobs, %{rescued: [], discarded: []}, fn job, result ->
        exhausted? = job.attempt >= job.max_attempts
        state = if exhausted?, do: "discarded", else: "available"

        error = %{
          "at" => DateTime.to_iso8601(now),
          "attempt" => job.attempt,
          "error" => "CSV attempt recovered after acquiring its released job-row lock"
        }

        {1, _} =
          Repo.update_all(from(j in Oban.Job, where: j.id == ^job.id),
            set: [state: state, scheduled_at: now, discarded_at: if(exhausted?, do: now)],
            push: [errors: error]
          )

        key = if exhausted?, do: :discarded, else: :rescued
        Map.update!(result, key, &[job.id | &1])
      end)
    end)
  end
end
