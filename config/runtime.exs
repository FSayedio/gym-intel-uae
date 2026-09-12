import Config

config :gym_intel, GymIntel.Repo,
  database: System.get_env("DATABASE_NAME", "gym_intel_dev"),
  username: System.get_env("DATABASE_USER", "gym_intel"),
  hostname: System.get_env("DATABASE_HOST", "postgres"),
  port: System.get_env("DATABASE_PORT", "5432") |> String.to_integer(),
  pool_size: System.get_env("DATABASE_POOL_SIZE", "5") |> String.to_integer()
