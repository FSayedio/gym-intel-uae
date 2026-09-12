import Config

config :gym_intel, ecto_repos: [GymIntel.Repo]

config :gym_intel, Oban,
  repo: GymIntel.Repo,
  queues: [imports: 1]
