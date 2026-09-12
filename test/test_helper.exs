database_tests? = System.get_env("RUN_DB_TESTS") == "true"

ExUnit.start(exclude: if(database_tests?, do: [], else: [:database]))

if database_tests? do
  unless Application.fetch_env!(:gym_intel, GymIntel.Repo)[:database] == "gym_intel_test" do
    raise "Database tests require DATABASE_NAME=gym_intel_test; refusing any other database"
  end

  {:ok, _} = Application.ensure_all_started(:ecto_sql)
  {:ok, _} = Application.ensure_all_started(:postgrex)
  {:ok, _} = Application.ensure_all_started(:oban)
  {:ok, _} = GymIntel.Repo.start_link(pool: Ecto.Adapters.SQL.Sandbox)
  Ecto.Adapters.SQL.Sandbox.mode(GymIntel.Repo, :manual)
end
