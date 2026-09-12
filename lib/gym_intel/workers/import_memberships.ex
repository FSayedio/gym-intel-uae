defmodule GymIntel.Workers.ImportMemberships do
  @moduledoc "Queues a small UTF-8 CSV snapshot and imports it through the imports queue."
  use Oban.Worker, queue: :imports, max_attempts: 3

  alias GymIntel.MembershipImporter

  @max_bytes 1_000_000

  def enqueue_file(path) do
    with {:ok, contents} <- File.read(path),
         :ok <- check_contents(contents) do
      %{"csv" => contents}
      |> new()
      |> Oban.insert()
    end
  end

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"csv" => contents}}) when is_binary(contents) do
    with :ok <- check_contents(contents),
         {:ok, result} <- MembershipImporter.import_csv(contents) do
      {:ok, result}
    else
      {:error, reason} -> {:cancel, reason}
    end
  end

  def perform(%Oban.Job{}), do: {:cancel, :invalid_arguments}

  defp check_contents(contents) do
    cond do
      byte_size(contents) > @max_bytes -> {:error, :csv_too_large}
      not String.valid?(contents) -> {:error, :invalid_utf8}
      true -> :ok
    end
  end
end
