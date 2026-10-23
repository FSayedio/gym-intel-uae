defmodule GymIntel.MixProject do
  use Mix.Project

  def project do
    [
      app: :gym_intel,
      version: "0.1.0",
      elixir: "~> 1.20",
      start_permanent: Mix.env() == :prod,
      releases: [gym_intel: [include_executables_for: [:unix]]],
      deps: deps()
    ]
  end

  def application do
    [
      extra_applications: [:logger, :crypto],
      mod: {GymIntel.Application, []}
    ]
  end

  defp deps do
    [
      {:decimal, "~> 3.1.2"},
      {:ecto_sql, "~> 3.14.0"},
      {:postgrex, "~> 0.22.4"},
      {:oban, "~> 2.24.1"},
      {:jason, "~> 1.4"},
      {:nimble_csv, "~> 1.3.0"}
    ]
  end
end
