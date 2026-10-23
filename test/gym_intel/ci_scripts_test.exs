defmodule GymIntel.CIScriptsTest do
  use ExUnit.Case, async: true

  setup do
    directory =
      Path.join(System.tmp_dir!(), "gym-intel-ci-script-#{System.unique_integer([:positive])}")

    File.mkdir!(directory)
    File.chmod!(directory, 0o700)
    password = Path.join(directory, "test-password")
    log = Path.join(directory, "calls")
    executable = Path.join(directory, "mix")
    File.write!(password, "disposable-test-only")
    File.chmod!(password, 0o600)

    File.write!(executable, """
    #!/bin/sh
    set -eu
    if [ "${HEX_OFFLINE+x}" = x ] || [ "${HEX_IGNORE_ADVISORIES+x}" = x ] ||
      [ "${HEX_IGNORE_RETIREMENTS+x}" = x ]; then
      echo 'audit bypass environment leaked' >&2
      exit 91
    fi
    printf '%s\n' "$*" >> "$STUB_MIX_LOG"
    if [ "$1" = "${STUB_FAIL_TASK:-}" ]; then
      echo 'simulated check failure' >&2
      exit 17
    fi
    """)

    File.chmod!(executable, 0o755)

    on_exit(fn ->
      for path <- [password, log, executable], do: File.rm(path)
      File.rmdir!(directory)
    end)

    env = [
      {"PATH", directory <> ":" <> System.fetch_env!("PATH")},
      {"MIX_ENV", "test"},
      {"RUN_DB_TESTS", "true"},
      {"DATABASE_NAME", "gym_intel_test"},
      {"DATABASE_PASSWORD_FILE", password},
      {"STUB_MIX_LOG", log},
      {"STUB_FAIL_TASK", nil}
    ]

    {:ok, env: env, log: log}
  end

  test "audit runs after locked resolution and before all application checks", context do
    {_output, 0} = run_checks(context.env)

    assert File.read!(context.log) == """
           deps.get --check-locked
           hex.audit
           format --check-formatted
           compile --warnings-as-errors
           ecto.create
           ecto.migrate
           test --no-start
           """
  end

  test "audit failures stop before formatting, compilation or database work", context do
    {output, 17} = run_checks(put_env(context.env, "STUB_FAIL_TASK", "hex.audit"))

    assert output =~ "simulated check failure"
    assert File.read!(context.log) == "deps.get --check-locked\nhex.audit\n"
  end

  test "locked dependency failures stop before the audit", context do
    {_output, 17} = run_checks(put_env(context.env, "STUB_FAIL_TASK", "deps.get"))
    assert File.read!(context.log) == "deps.get --check-locked\n"
  end

  test "inherited offline and ignore overrides cannot bypass the CI audit", context do
    env =
      context.env
      |> put_env("HEX_OFFLINE", "1")
      |> put_env("HEX_IGNORE_ADVISORIES", "CVE-2026-97853")
      |> put_env("HEX_IGNORE_RETIREMENTS", "decimal")

    {_output, 0} = run_checks(env)
    assert File.read!(context.log) =~ "hex.audit\n"
  end

  test "non-test database and environment settings are rejected before Mix", context do
    for {key, value} <- [
          {"DATABASE_NAME", "gym_intel_dev"},
          {"MIX_ENV", "prod"},
          {"RUN_DB_TESTS", "false"}
        ] do
      {output, 1} = run_checks(put_env(context.env, key, value))
      assert output =~ "CI checks require"
      refute File.exists?(context.log)
    end
  end

  test "a missing test password is rejected before Mix", context do
    {output, 1} = run_checks(put_env(context.env, "DATABASE_PASSWORD_FILE", ""))
    assert output =~ "nonempty test-only"
    refute File.exists?(context.log)
  end

  defp run_checks(env) do
    System.cmd("sh", ["scripts/ci-checks.sh"], env: env, stderr_to_stdout: true)
  end

  defp put_env(env, key, value), do: List.keystore(env, key, 0, {key, value})
end
