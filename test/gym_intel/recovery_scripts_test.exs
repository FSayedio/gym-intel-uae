defmodule GymIntel.RecoveryScriptsTest do
  use ExUnit.Case, async: true

  setup do
    directory =
      Path.join(
        System.tmp_dir!(),
        "gym-intel-recovery-unit-#{System.unique_integer([:positive])}"
      )

    File.mkdir!(directory)
    File.chmod!(directory, 0o700)
    on_exit(fn -> File.rm_rf!(directory) end)
    %{directory: directory}
  end

  defp private_file(path, text) do
    File.write!(path, text)
    File.chmod!(path, 0o600)
  end

  defp sha(text), do: :crypto.hash(:sha256, text) |> Base.encode16(case: :lower)

  defp root(directory) do
    path = Path.join(directory, "backups")
    File.mkdir!(path)
    File.chmod!(path, 0o700)
    private_file(Path.join(path, ".gym-intel-backups-v1"), "gym-intel-backups-v1\n")
    path
  end

  # Synthetic bundles exercise filesystem policy, not actual restore validity.
  defp bundle(root, number) do
    name = "backup-20000101T0000#{String.pad_leading(to_string(number), 2, "0")}Z-ABCDE#{number}"
    path = Path.join(root, name)
    File.mkdir!(path)
    File.chmod!(path, 0o700)
    archive = "SYNTHETIC POLICY FIXTURE #{number}"
    baseline = "{\"synthetic\":#{number}}\n"

    for {name, text} <- [
          {"database.dump", archive},
          {"baseline.json", baseline},
          {"archive.sha256", sha(archive) <> "\n"},
          {"baseline.sha256", sha(baseline) <> "\n"},
          {"format", "gym-intel-db-backup-v1\n"},
          {"image-id", "sha256:" <> String.duplicate("a", 64) <> "\n"},
          {"verified", "gym-intel-restore-verified-v1 #{sha(archive)} #{sha(baseline)}\n"}
        ] do
      private_file(Path.join(path, name), text)
    end

    path
  end

  defp policy(root, newest \\ "") do
    System.cmd(
      "sh",
      [
        "-ec",
        ~s(project_dir=$1; backup_root=$2; . "$1/scripts/recovery/common.sh"; recovery_prune "$3"),
        "recovery-policy",
        File.cwd!(),
        root,
        newest
      ],
      stderr_to_stdout: true
    )
  end

  test "recovery helpers reject invalid arguments before touching Docker" do
    for arguments <- [["unexpected"], ["--directory", "relative/backups"], ["--directory", "/"]] do
      {_output, status} =
        System.cmd("sh", ["scripts/backup-database.sh" | arguments], stderr_to_stdout: true)

      assert status != 0
    end

    for arguments <- [[], ["relative"], ["/tmp/other"], ["a", "b"]] do
      {_output, 2} =
        System.cmd("sh", ["scripts/verify-database-backup.sh" | arguments],
          stderr_to_stdout: true
        )
    end
  end

  test "retention preserves seven latest verified bundles", %{directory: directory} do
    root = root(directory)
    bundles = for number <- 0..7, do: bundle(root, number)
    {_message, 0} = policy(root)
    refute File.exists?(hd(bundles))
    assert Enum.all?(tl(bundles), &File.dir?/1)
    assert File.exists?(Path.join(root, ".gym-intel-backups-v1"))
  end

  test "tampering stops retention before any deletion", %{directory: directory} do
    root = root(directory)
    bundles = for number <- 0..7, do: bundle(root, number)
    File.write!(Path.join(List.last(bundles), "database.dump"), "CORRUPTED FIXTURE")
    {_message, status} = policy(root)
    assert status != 0
    assert Enum.all?(bundles, &File.dir?/1)
  end

  test "backwards backup timestamps stop retention before deletion", %{directory: directory} do
    root = root(directory)
    bundles = for number <- 0..7, do: bundle(root, number)
    {message, 1} = policy(root, hd(bundles))
    assert message =~ "clock/order moved backwards"
    assert Enum.all?(bundles, &File.dir?/1)
  end

  test "unknown files and symlinks are never swept away", %{directory: directory} do
    root = root(directory)
    bundles = for number <- 0..7, do: bundle(root, number)
    protected = Path.join(hd(bundles), "keep-me.txt")
    private_file(protected, "unrelated")
    {_message, status} = policy(root)
    assert status != 0
    assert Enum.all?(bundles, &File.dir?/1)
    assert File.read!(protected) == "unrelated"
    File.rm!(protected)
    File.rename!(List.last(bundles), Path.join(directory, "outside"))
    File.ln_s!(Path.join(directory, "outside"), List.last(bundles))
    {_message, status} = policy(root)
    assert status != 0
    assert File.dir?(Path.join(directory, "outside"))
    assert File.dir?(hd(bundles))
  end

  test "public permissions and unverified markers cannot pass retention", %{directory: directory} do
    root = root(directory)
    bundles = for number <- 0..7, do: bundle(root, number)
    File.chmod!(Path.join(hd(bundles), "database.dump"), 0o644)
    {_message, status} = policy(root)
    assert status != 0
    assert Enum.all?(bundles, &File.dir?/1)
    File.chmod!(Path.join(hd(bundles), "database.dump"), 0o600)
    File.rm!(Path.join(hd(bundles), "verified"))
    {_message, status} = policy(root)
    assert status != 0
    assert Enum.all?(bundles, &File.dir?/1)
  end

  test "checksum rejection happens before Docker starts", %{directory: directory} do
    root = root(directory)
    bundle = bundle(root, 1)
    File.write!(Path.join(bundle, "database.dump"), "CORRUPTED FIXTURE")
    docker = Path.join(directory, "docker")
    File.write!(docker, "#!/bin/sh\necho DOCKER_MUST_NOT_RUN\nexit 99\n")
    File.chmod!(docker, 0o755)

    {message, status} =
      System.cmd("sh", ["scripts/verify-database-backup.sh", bundle],
        env: [{"PATH", directory <> ":" <> System.fetch_env!("PATH")}],
        stderr_to_stdout: true
      )

    assert status == 1
    assert message =~ "checksum mismatch"
    refute message =~ "DOCKER_MUST_NOT_RUN"
  end

  defp fake_docker(directory) do
    docker = Path.join(directory, "docker")

    File.write!(docker, """
    #!/bin/sh
    case "$*" in
      'compose ps -q postgres') echo fixture-postgres ;;
      'compose ps -a -q app') echo fixture-app ;;
      *com.docker.compose.project*) echo gym-intel-uae ;;
      *State.Running*fixture-app) echo "${FAKE_RUNNING:-true}" ;;
      *State.Running*) echo true ;;
      *'{{.Image}}'*) printf 'sha256:%064d\\n' 0 ;;
      *current_database*) echo gym_intel_dev ;;
      *pg_stat_activity*) echo t ;;
      *'SELECT count(*)'*) echo "${FAKE_PENDING:-0}" ;;
      *pg_dump*) echo SYNTHETIC_PARTIAL_DUMP; exit 42 ;;
      'exec -i fixture-postgres sh /opt/gym-intel/psql.sh -qAt')
        cat >/dev/null; echo '{"fixture":true}' ;;
      'stop --time 20 fixture-app') echo stop >> "$FAKE_ACTIONS" ;;
      'start fixture-app') echo start >> "$FAKE_ACTIONS"; exit "${FAKE_START_FAIL:-0}" ;;
      *) echo 'Unexpected fixture command' >&2; exit 99 ;;
    esac
    """)

    File.chmod!(docker, 0o755)

    [
      {"PATH", directory <> ":" <> System.fetch_env!("PATH")},
      {"FAKE_ACTIONS", Path.join(directory, "actions")}
    ]
  end

  test "failed capture restarts the original app and never publishes or prunes", %{
    directory: directory
  } do
    root = root(directory)
    existing = bundle(root, 1)

    {message, 42} =
      System.cmd("sh", ["scripts/backup-database.sh", "--directory", root],
        env: fake_docker(directory),
        stderr_to_stdout: true
      )

    assert File.read!(Path.join(directory, "actions")) == "stop\nstart\n"
    assert File.dir?(existing)
    refute File.exists?(Path.join(root, ".backup.lock"))
    assert message =~ "Unverified attempt retained"
    assert Enum.count(File.ls!(root), &String.starts_with?(&1, "backup-")) == 1
  end

  test "unfinished jobs refuse capture before stopping the app", %{directory: directory} do
    root = root(directory)

    {message, 1} =
      System.cmd("sh", ["scripts/backup-database.sh", "--directory", root],
        env: fake_docker(directory) ++ [{"FAKE_PENDING", "1"}],
        stderr_to_stdout: true
      )

    assert message =~ "Unfinished jobs"
    refute File.exists?(Path.join(directory, "actions"))
    refute File.exists?(Path.join(root, ".backup.lock"))
  end

  test "an originally stopped app is not started after failure", %{directory: directory} do
    root = root(directory)

    {_message, 42} =
      System.cmd("sh", ["scripts/backup-database.sh", "--directory", root],
        env: fake_docker(directory) ++ [{"FAKE_RUNNING", "false"}],
        stderr_to_stdout: true
      )

    refute File.exists?(Path.join(directory, "actions"))
  end

  test "unmanaged, insecure and symlinked roots are not taken over", %{directory: directory} do
    unmanaged = Path.join(directory, "unmanaged")
    File.mkdir!(unmanaged)
    File.chmod!(unmanaged, 0o700)
    private_file(Path.join(unmanaged, "keep.txt"), "unrelated")

    {_message, 1} =
      System.cmd("sh", ["scripts/backup-database.sh", "--directory", unmanaged],
        stderr_to_stdout: true
      )

    refute File.exists?(Path.join(unmanaged, ".gym-intel-backups-v1"))
    assert File.read!(Path.join(unmanaged, "keep.txt")) == "unrelated"
    root = root(directory)
    File.chmod!(root, 0o755)

    {_message, 1} =
      System.cmd("sh", ["scripts/backup-database.sh", "--directory", root],
        stderr_to_stdout: true
      )

    assert Bitwise.band(File.stat!(root).mode, 0o777) == 0o755
    File.chmod!(root, 0o700)
    link = Path.join(directory, "linked")
    File.ln_s!(root, link)

    {_message, 1} =
      System.cmd("sh", ["scripts/backup-database.sh", "--directory", link],
        stderr_to_stdout: true
      )

    assert File.dir?(root)
  end

  test "a stale capture lock is reported and preserved", %{directory: directory} do
    root = root(directory)
    lock = Path.join(root, ".backup.lock")
    File.mkdir!(lock)
    private_file(Path.join(lock, "owner"), "TEST ONLY LOCK OWNER")

    {message, 1} =
      System.cmd("sh", ["scripts/backup-database.sh", "--directory", root],
        stderr_to_stdout: true
      )

    assert message =~ "stale lock"
    assert File.read!(Path.join(lock, "owner")) == "TEST ONLY LOCK OWNER"
  end

  test "restart failure is surfaced without deleting earlier good backups", %{
    directory: directory
  } do
    root = root(directory)
    existing = bundle(root, 1)

    {message, 1} =
      System.cmd("sh", ["scripts/backup-database.sh", "--directory", root],
        env: fake_docker(directory) ++ [{"FAKE_START_FAIL", "41"}],
        stderr_to_stdout: true
      )

    assert message =~ "app restart failed"
    assert File.read!(Path.join(directory, "actions")) == "stop\nstart\n"
    assert File.dir?(existing)
    refute File.exists?(Path.join(root, ".backup.lock"))
  end
end
