defmodule GymIntel.Application do
  use Application

  @impl true
  def start(_type, _args) do
    children = [
      GymIntel.Repo,
      {Finch,
       name: GymIntel.SourceHTTP,
       pools: %{default: [size: 1, count: 1, conn_opts: [transport_opts: [timeout: 5_000]]]}},
      {Oban, Application.fetch_env!(:gym_intel, Oban)}
    ]

    Supervisor.start_link(children,
      strategy: :one_for_one,
      name: GymIntel.Supervisor
    )
  end
end
