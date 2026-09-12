defmodule GymIntel.Application do
  use Application

  @impl true
  def start(_type, _args) do
    children = [
      GymIntel.Repo,
      {Oban, Application.fetch_env!(:gym_intel, Oban)}
    ]

    Supervisor.start_link(children,
      strategy: :one_for_one,
      name: GymIntel.Supervisor
    )
  end
end
