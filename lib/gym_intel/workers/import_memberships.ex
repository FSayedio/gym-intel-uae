defmodule GymIntel.Workers.ImportMemberships do
  @moduledoc "Queues a small UTF-8 CSV snapshot and imports it through the imports queue."
  use Oban.Worker, queue: :imports, max_attempts: 3

  alias GymIntel.{MembershipCSV, MembershipImporter}

  def enqueue_file(path) do
    with {:ok, contents} <- MembershipCSV.read_contents(path),
         {:ok, _memberships} <- MembershipCSV.parse(contents) do
      %{"csv" => contents}
      |> new()
      |> Oban.insert()
    end
  end

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"csv" => contents}}) when is_binary(contents) do
    with {:ok, result} <- MembershipImporter.import_csv(contents) do
      {:ok, result}
    else
      {:error, reason} -> {:cancel, reason}
    end
  end

  def perform(%Oban.Job{}), do: {:cancel, :invalid_arguments}
end
