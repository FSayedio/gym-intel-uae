import Config

config :gym_intel, ecto_repos: [GymIntel.Repo]

config :gym_intel, Oban,
  repo: GymIntel.Repo,
  queues: [imports: 1, source_checks: 1],
  plugins: [
    {Oban.Cron, crontab: [{"0 5 * * 1", GymIntel.Workers.CheckSources}], timezone: "Etc/UTC"}
  ]

# Never launch external source checks from a test application or CI fixture.
if config_env() == :test do
  config :gym_intel, Oban, queues: false, plugins: false, testing: :manual
end
