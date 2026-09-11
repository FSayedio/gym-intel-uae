defmodule GymIntel.DatabaseProbe do
  use GenServer

  require Logger

  @retry_after_ms 1_000

  def start_link(_options) do
    GenServer.start_link(__MODULE__, :not_connected, name: __MODULE__)
  end

  @impl true
  def init(state) do
    {:ok, state, {:continue, :probe}}
  end

  @impl true
  def handle_continue(:probe, state) do
    {:noreply, probe(state)}
  end

  @impl true
  def handle_info(:probe, state) do
    {:noreply, probe(state)}
  end

  defp probe(:connected), do: :connected

  defp probe(:not_connected) do
    host = System.get_env("DATABASE_HOST", "postgres")
    port = System.get_env("DATABASE_PORT", "5432") |> String.to_integer()

    case :gen_tcp.connect(String.to_charlist(host), port, [:binary, active: false], 1_000) do
      {:ok, socket} ->
        :ok = :gen_tcp.close(socket)
        Logger.info("PostgreSQL is reachable")
        :connected

      {:error, reason} ->
        Logger.warning("PostgreSQL is not reachable yet: #{inspect(reason)}")
        Process.send_after(self(), :probe, @retry_after_ms)
        :not_connected
    end
  end
end
