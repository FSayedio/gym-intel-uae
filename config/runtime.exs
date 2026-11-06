import Config

# Explicit opt-in in the real deployment. Test/recovery release containers do
# not contact external sites just because they start the application.
source_checks? = System.get_env("SOURCE_CHECKS_ENABLED") == "true" and config_env() != :test
csv_recovery? = System.get_env("CSV_IMPORT_RECOVERY_ENABLED") == "true" and config_env() != :test

plugins =
  if source_checks?,
    do: Application.fetch_env!(:gym_intel, Oban)[:plugins] || [],
    else: []

plugins = if csv_recovery?, do: plugins ++ [GymIntel.CSVImportRecovery.Plugin], else: plugins
config :gym_intel, Oban, plugins: if(plugins == [], do: false, else: plugins)

if not source_checks? and config_env() != :test,
  do: config(:gym_intel, Oban, queues: [imports: 1])

database_password =
  System.fetch_env!("DATABASE_PASSWORD_FILE")
  |> File.read!()
  |> String.trim_trailing("\n")

if database_password == "" do
  raise "DATABASE_PASSWORD_FILE must contain a nonempty password"
end

config :gym_intel, GymIntel.Repo,
  database: System.get_env("DATABASE_NAME", "gym_intel_dev"),
  username: System.get_env("DATABASE_USER", "gym_intel"),
  password: database_password,
  hostname: System.get_env("DATABASE_HOST", "postgres"),
  port: System.get_env("DATABASE_PORT", "5432") |> String.to_integer(),
  pool_size: System.get_env("DATABASE_POOL_SIZE", "5") |> String.to_integer()
