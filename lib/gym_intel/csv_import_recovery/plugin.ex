defmodule GymIntel.CSVImportRecovery.Plugin do
  @moduledoc "Opt-in periodic CSV recovery. Reports counts, never CSV contents."
  use GenServer
  @behaviour Oban.Plugin
  require Logger

  @impl Oban.Plugin
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: opts[:name])

  @impl Oban.Plugin
  def validate(opts) do
    if Keyword.keys(opts) -- [:conf, :name] == [],
      do: :ok,
      else: {:error, "CSV recovery accepts only the Oban conf and name"}
  end

  @impl GenServer
  def init(opts) do
    schedule()
    {:ok, Keyword.fetch!(opts, :conf)}
  end

  @impl GenServer
  def handle_info(:sweep, conf) do
    try do
      case GymIntel.CSVImportRecovery.sweep() do
        {:ok, %{rescued: rescued, discarded: discarded}} ->
          if rescued != [], do: Oban.Notifier.notify(conf, :insert, %{queue: "imports"})

          if rescued != [] or discarded != [] do
            Logger.info("CSV recovery: rescued=#{length(rescued)} discarded=#{length(discarded)}")
          end

        {:error, _} ->
          Logger.warning("CSV recovery did not complete; no success claimed")
      end
    rescue
      _ -> Logger.warning("CSV recovery unavailable; will check again later")
    end

    schedule()
    {:noreply, conf}
  end

  defp schedule, do: Process.send_after(self(), :sweep, 30_000)
end
