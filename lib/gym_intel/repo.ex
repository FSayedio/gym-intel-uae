defmodule GymIntel.Repo do
  use Ecto.Repo,
    otp_app: :gym_intel,
    adapter: Ecto.Adapters.Postgres
end
