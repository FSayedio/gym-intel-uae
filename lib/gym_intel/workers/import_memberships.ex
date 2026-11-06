defmodule GymIntel.Workers.ImportMemberships do
  @moduledoc "Queues a small UTF-8 CSV snapshot and imports it through the imports queue."
  use Oban.Worker, queue: :imports, max_attempts: 3

  alias GymIntel.{CSVImportRecovery, MembershipCSV, MembershipImporter}

  @impl Oban.Worker
  def new(args, opts) do
    meta = Map.put(Keyword.get(opts, :meta, %{}), CSVImportRecovery.version_key(), 1)
    super(args, Keyword.put(opts, :meta, meta))
  end

  @impl Oban.Worker
  def timeout(_job), do: CSVImportRecovery.execution_limit()

  def enqueue_file(path) do
    with {:ok, contents} <- MembershipCSV.read_contents(path),
         {:ok, _memberships} <- MembershipCSV.parse(contents) do
      %{"csv" => contents}
      |> new()
      |> Oban.insert()
    end
  end

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"csv" => contents}} = job) when is_binary(contents) do
    with {:ok, memberships} <- MembershipCSV.parse(contents) do
      case memberships do
        [] -> {:ok, :empty}
        [_ | _] -> CSVImportRecovery.with_attempt(job, fn -> import_snapshot(contents) end)
      end
    else
      {:error, reason} -> {:cancel, reason}
    end
  end

  def perform(%Oban.Job{}), do: {:cancel, :invalid_arguments}

  defp import_snapshot(contents) do
    case MembershipImporter.import_csv(contents) do
      {:ok, result} -> {:ok, result}
      {:error, reason} -> {:cancel, reason}
    end
  end
end
