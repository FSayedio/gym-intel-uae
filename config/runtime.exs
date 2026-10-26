import Config

# Explicit opt-in in the real deployment. Test/recovery release containers do
# not contact external sites just because they start the application.
unless System.get_env("SOURCE_CHECKS_ENABLED") == "true" and config_env() != :test do
  config :gym_intel, Oban, plugins: false
  if config_env() != :test, do: config(:gym_intel, Oban, queues: [imports: 1])
end

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
