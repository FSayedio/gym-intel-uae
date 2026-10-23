defmodule GymIntel.OperatorScriptsTest do
  use ExUnit.Case, async: true

  test "import helper rejects missing/extra arguments and paths outside the data mount" do
    for args <- [[], ["data/a.csv", "data/b.csv"], ["/tmp/file.csv"], [".secrets/password"]] do
      {message, status} =
        System.cmd("sh", ["scripts/import-csv.sh" | args], stderr_to_stdout: true)

      assert status == 2
      refute message =~ "Container"
    end
  end

  test "import helper rejects traversal paths and nonexistent files before Docker" do
    for path <- ["data/../README.md", "data/a/../../.secrets/password", "data/.", "data/a/.."] do
      {message, 2} = System.cmd("sh", ["scripts/import-csv.sh", path], stderr_to_stdout: true)
      assert message =~ "traversal"
    end

    {message, 1} =
      System.cmd("sh", ["scripts/import-csv.sh", "data/test-definitely-missing.csv"],
        stderr_to_stdout: true
      )

    assert message =~ "does not exist"
  end

  test "valid input maps to a literal container path and propagates command failures" do
    directory =
      Path.join(System.tmp_dir!(), "gym-intel-operator-#{System.unique_integer([:positive])}")

    File.mkdir!(directory)
    docker = Path.join(directory, "docker")
    File.write!(docker, "#!/bin/sh\nprintf '<%s>\\n' \"$@\"\nexit \"${STUB_EXIT:-0}\"\n")
    File.chmod!(docker, 0o755)

    on_exit(fn ->
      File.rm!(docker)
      File.rmdir!(directory)
    end)

    env = [{"PATH", directory <> ":" <> System.fetch_env!("PATH")}, {"STUB_EXIT", "0"}]

    {output, 0} =
      System.cmd("sh", ["scripts/import-csv.sh", "data/memberships.csv"], env: env)

    assert output =~ "<IMPORT_CSV_PATH=/app/data/memberships.csv>"
    assert output =~ "<bin/gym_intel>\n<eval>\n<GymIntel.Release.enqueue()>"
    refute output =~ "DATABASE_PASSWORD"

    {_output, 7} =
      System.cmd("sh", ["scripts/import-csv.sh", "data/memberships.csv"],
        env: List.keyreplace(env, "STUB_EXIT", 0, {"STUB_EXIT", "7"})
      )
  end
end
