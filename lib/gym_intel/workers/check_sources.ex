defmodule GymIntel.Workers.CheckSources do
  @moduledoc "Weekly public-page checks, separate from CSV imports and dashboard publication."
  use Oban.Worker,
    queue: :source_checks,
    max_attempts: 3,
    unique: [period: 300, states: [:available, :scheduled, :executing, :retryable]]

  @impl Oban.Worker
  def perform(%Oban.Job{id: id}) do
    case GymIntel.SourceMonitor.check(job_id: id) do
      {:ok, report} -> {:ok, report}
      {:error, :check_already_running} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @impl Oban.Worker
  def timeout(_job), do: :timer.minutes(4)
end
