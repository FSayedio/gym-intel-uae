defmodule GymIntel.UpdateScriptsTest do
  use ExUnit.Case, async: true

  setup do
    directory =
      Path.join(System.tmp_dir!(), "gym-intel-update-#{System.unique_integer([:positive])}")

    project = Path.join(directory, "project")
    root = Path.join(directory, "backups")
    File.mkdir_p!(Path.join(project, "scripts/recovery"))
    File.mkdir_p!(Path.join(project, "data"))
    File.mkdir!(root)
    File.chmod!(root, 0o700)
    File.cp!("scripts/update-dashboard.sh", Path.join(project, "scripts/update-dashboard.sh"))
    File.cp!("scripts/recovery/common.sh", Path.join(project, "scripts/recovery/common.sh"))
    File.write!(Path.join(project, "data/test.csv"), "TEST INPUT NEVER PRINTED")

    bundle = Path.join(root, "backup-20000101T000000Z-ABCDEF")
    File.mkdir!(bundle)
    File.chmod!(bundle, 0o700)
    sha = :crypto.hash(:sha256, "fixture") |> Base.encode16(case: :lower)
    table_hash = String.duplicate("a", 64)

    baseline =
      Enum.map_join(
        ~w(memberships membership_notes membership_imports oban_jobs),
        "\n",
        fn table ->
          Jason.encode!(%{"table" => table, "sha256" => table_hash, "rows" => 0}, pretty: false)
          |> String.replace(":", ": ")
        end
      ) <> "\n"

    baseline_sha = :crypto.hash(:sha256, baseline) |> Base.encode16(case: :lower)

    state_sha =
      :crypto.hash(:sha256, Enum.join(List.duplicate(table_hash, 4), ":"))
      |> Base.encode16(case: :lower)

    for {file, text} <- [
          {"database.dump", "fixture"},
          {"baseline.json", baseline},
          {"archive.sha256", sha},
          {"baseline.sha256", baseline_sha},
          {"image-id", "sha256:" <> String.duplicate("a", 64)},
          {"format", "gym-intel-db-backup-v1"},
          {"verified", "gym-intel-restore-verified-v1 #{sha} #{baseline_sha}"}
        ] do
      File.write!(
        Path.join(bundle, file),
        text <> if(file in ["database.dump", "baseline.json"], do: "", else: "\n")
      )

      File.chmod!(Path.join(bundle, file), 0o600)
    end

    File.write!(Path.join(root, ".gym-intel-backups-v1"), "gym-intel-backups-v1\n")
    File.chmod!(Path.join(root, ".gym-intel-backups-v1"), 0o600)

    File.write!(Path.join(project, "scripts/backup-database.sh"), """
    #!/bin/sh
    echo backup >> "$FAKE_ACTIONS"
    test "${FAKE_BACKUP_FAIL:-0}" = 0 || exit 17
    printf '%s\\n' "$FAKE_BUNDLE" > "$2/.update.lock/backup"
    """)

    docker = Path.join(directory, "docker")

    File.write!(docker, """
    #!/bin/sh
    case "$*" in
      'compose ps -q postgres') echo fixture-postgres ;;
      'compose ps -q app') echo fixture-app ;;
      *com.docker.compose.project*) echo gym-intel-uae ;;
      *State.Running*) echo true ;;
      *current_database*) echo gym_intel_dev ;;
      *'SELECT count(*)'*) echo "${FAKE_PENDING:-0}" ;;
      *GymIntel.Release.update*)
        echo import >> "$FAKE_ACTIONS"
        test "${FAKE_IMPORT_FAIL:-0}" = 0 || exit 19
        printf 'UPDATE_VERIFIED 42 %064d\\n' 1 ;;
      *'update_cleanup.sql -f -')
        cat >/dev/null
        echo cleanup >> "$FAKE_ACTIONS"
        exit "${FAKE_CLEANUP_FAIL:-0}" ;;
      *update_state.sql*) printf '%s\\n' "${FAKE_STATE_OVERRIDE:-$FAKE_STATE}" ;;
      *) echo 'Unexpected synthetic command' >&2; exit 99 ;;
    esac
    """)

    File.chmod!(docker, 0o755)
    on_exit(fn -> File.rm_rf!(directory) end)

    env = [
      {"PATH", directory <> ":" <> System.fetch_env!("PATH")},
      {"FAKE_ACTIONS", Path.join(directory, "actions")},
      {"FAKE_BUNDLE", bundle},
      {"FAKE_STATE", state_sha}
    ]

    %{directory: directory, project: project, root: root, env: env, bundle: bundle}
  end

  defp run_update(context, extra \\ []) do
    System.cmd(
      "sh",
      [
        Path.join(context.project, "scripts/update-dashboard.sh"),
        "data/test.csv",
        "--directory",
        context.root
      ],
      env: context.env ++ extra,
      stderr_to_stdout: true
    )
  end

  defp actions(context) do
    case File.read(Path.join(context.directory, "actions")) do
      {:ok, text} -> String.split(text, "\n", trim: true)
      {:error, :enoent} -> []
    end
  end

  test "success orders import, verified backup and cleanup", context do
    {output, 0} = run_update(context)
    assert actions(context) == ["import", "backup", "cleanup"]
    assert output =~ "PASS: import committed"
    refute output =~ "TEST INPUT NEVER PRINTED"
    refute File.exists?(Path.join(context.root, ".update.lock"))
    assert File.dir?(context.bundle)
  end

  test "failed backup withholds cleanup and retains prior backup", context do
    {output, status} = run_update(context, [{"FAKE_BACKUP_FAIL", "1"}])
    assert status != 0
    assert output =~ "backup-verification"
    assert actions(context) == ["import", "backup"]
    assert File.dir?(context.bundle)
    refute File.exists?(Path.join(context.root, ".update.lock"))
  end

  test "a verified backup of different state cannot permit database cleanup", context do
    {output, status} = run_update(context, [{"FAKE_STATE_OVERRIDE", String.duplicate("b", 64)}])
    assert status != 0
    assert output =~ "does not match prepared protected state"
    assert actions(context) == ["import", "backup"]
  end

  test "failed import or unfinished jobs prevent backup and cleanup", context do
    {output, status} = run_update(context, [{"FAKE_PENDING", "1"}])
    assert status != 0
    assert output =~ "Unfinished jobs"
    assert actions(context) == []
    {_output, status} = run_update(context, [{"FAKE_IMPORT_FAIL", "1"}])
    assert status != 0
    assert actions(context) == ["import"]
  end

  test "stale update lock is preserved rather than taken over", context do
    lock = Path.join(context.root, ".update.lock")
    File.mkdir!(lock)
    File.write!(Path.join(lock, "owner"), "TEST STALE OWNER")
    {output, status} = run_update(context)
    assert status != 0
    assert output =~ "stale update lock"
    assert File.read!(Path.join(lock, "owner")) == "TEST STALE OWNER"
    assert actions(context) == []
  end

  test "cleanup failure remains failure after successful backup", context do
    {output, status} = run_update(context, [{"FAKE_CLEANUP_FAIL", "23"}])
    assert status == 23
    assert output =~ "current-data-and-job-cleanup"
    refute output =~ "PASS: import committed"
    assert File.dir?(context.bundle)
  end

  test "invalid paths are refused before any import" do
    for args <- [[], [".secrets/password"], ["data/../README.md"], ["data/missing.csv"]] do
      {_output, status} =
        System.cmd("sh", ["scripts/update-dashboard.sh" | args], stderr_to_stdout: true)

      assert status != 0
    end
  end
end
