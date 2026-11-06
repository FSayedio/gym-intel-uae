defmodule GymIntel.CSVImportRecoveryTest do
  use ExUnit.Case, async: false
  alias GymIntel.CSVImportRecovery

  @tag :tmp_dir
  test "recovery is explicitly opt-in and independent of source checks", %{tmp_dir: dir} do
    variables = ~w(SOURCE_CHECKS_ENABLED CSV_IMPORT_RECOVERY_ENABLED DATABASE_PASSWORD_FILE)
    previous = Map.new(variables, &{&1, System.get_env(&1)})
    previous_oban = Application.fetch_env!(:gym_intel, Oban)
    baseline = Config.Reader.read!("config/config.exs", env: :prod)[:gym_intel][Oban]
    password_file = Path.join(dir, "test-only-password")
    File.write!(password_file, "SYNTHETIC TEST ONLY")
    System.put_env("DATABASE_PASSWORD_FILE", password_file)
    Application.put_env(:gym_intel, Oban, baseline)

    on_exit(fn ->
      Enum.each(previous, fn
        {key, nil} -> System.delete_env(key)
        {key, value} -> System.put_env(key, value)
      end)

      Application.put_env(:gym_intel, Oban, previous_oban)
    end)

    for {source, recovery, expected} <- [
          {"false", "false", []},
          {"true", "false", [Oban.Cron]},
          {"false", "true", [CSVImportRecovery.Plugin]},
          {"true", "true", [Oban.Cron, CSVImportRecovery.Plugin]}
        ] do
      System.put_env("SOURCE_CHECKS_ENABLED", source)
      System.put_env("CSV_IMPORT_RECOVERY_ENABLED", recovery)
      result = Config.Reader.read!("config/runtime.exs", env: :prod)[:gym_intel][Oban]

      plugins =
        case result[:plugins] do
          false ->
            []

          entries ->
            Enum.map(entries, fn
              {module, _opts} -> module
              module -> module
            end)
        end

      assert plugins == expected
    end

    result = Config.Reader.read!("config/runtime.exs", env: :test)[:gym_intel][Oban]
    assert result[:plugins] == false
  end

  test "recovery cadence leaves room beyond the bounded attempt and accepts no hidden options" do
    assert CSVImportRecovery.execution_limit() == 120_000
    assert CSVImportRecovery.rescue_after() * 1_000 > CSVImportRecovery.execution_limit()
    assert :ok = CSVImportRecovery.Plugin.validate([])
    assert {:error, _} = CSVImportRecovery.Plugin.validate(rescue_after: 0)
  end
end
