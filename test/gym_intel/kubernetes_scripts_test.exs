defmodule GymIntel.KubernetesScriptsTest do
  use ExUnit.Case, async: true

  defp common(namespace, body) do
    System.cmd(
      "sh",
      [
        "-ec",
        "project_dir=$1; . scripts/kubernetes/common.sh; " <> body,
        "kubernetes-test",
        File.cwd!()
      ],
      env: [{"GYM_INTEL_KUBE_NAMESPACE", namespace}],
      stderr_to_stdout: true
    )
  end

  test "rejects arbitrary namespaces before contacting any cluster" do
    for namespace <- [
          "default",
          "kube-system",
          "gym-intel-test-production",
          "gym-intel;echo unsafe"
        ] do
      {_output, status} = common(namespace, "echo reached")
      assert status != 0
    end
  end

  test "accepts only the live namespace and generated numeric fixture namespaces" do
    for namespace <- ["gym-intel", "gym-intel-test-1792779954-123"] do
      assert {output, 0} = common(namespace, "printf '%s\\n' \"$kube_namespace\"")
      assert output == "#{namespace}\n"
    end
  end

  test "kubectl always receives private kubeconfig, context and namespace" do
    assert {output, 0} =
             common(
               "gym-intel-test-123-456",
               "kubectl() { printf '%s\\n' \"$@\"; }; kube get pods"
             )

    assert String.split(output, "\n", trim: true) == [
             "--kubeconfig",
             Path.join(File.cwd!(), ".local/kubernetes/kubeconfig"),
             "--context",
             "kind-gym-intel",
             "--namespace",
             "gym-intel-test-123-456",
             "get",
             "pods"
           ]
  end

  @tag :tmp_dir
  test "prepare repeatedly enables recovery only in the primary namespace", %{tmp_dir: dir} do
    for {namespace, enabled} <- [{"gym-intel", "true"}, {"gym-intel-test-123-456", "false"}] do
      project = Path.join(dir, namespace)
      scripts = Path.join(project, "scripts/kubernetes")
      bin = Path.join(project, "bin")
      File.mkdir_p!(scripts)
      File.mkdir_p!(bin)
      File.mkdir_p!(Path.join(project, ".local/kubernetes"))
      File.mkdir_p!(Path.join(project, ".secrets"))
      File.cp!("scripts/kubernetes/deploy.sh", Path.join(scripts, "deploy.sh"))

      # Exercise the real prepare script with inert transports. Namespace and
      # cluster guards have their own tests; no live cluster or Docker is used.
      File.write!(Path.join(scripts, "common.sh"), """
      kube_namespace=$GYM_INTEL_KUBE_NAMESPACE
      kube_root="$project_dir/.local/kubernetes"
      kube_image_file="$kube_root/runtime-image"
      kube_guard() { :; }
      kube() {
        case "$*" in
          'get deployment app'*) return 1 ;;
          'create configmap app-settings '*)
            printf '%s\\n' "$@" > "$project_dir/app-settings.args" ;;
          'apply -f -') cat >/dev/null ;;
        esac
      }
      """)

      File.write!(Path.join(bin, "docker"), """
      #!/bin/sh
      if [ "$1 $2" = 'image inspect' ]; then printf 'sha256:test-only\\n'; fi
      """)

      File.chmod!(Path.join(bin, "docker"), 0o700)

      for secret <-
            ~w(postgres_password postgres_app_password postgres_migrator_password grafana_database_password grafana_admin_password) do
        File.write!(Path.join(project, ".secrets/#{secret}"), "synthetic-test-only")
      end

      for _ <- 1..2 do
        assert {output, 0} =
                 System.cmd("sh", ["scripts/kubernetes/deploy.sh"],
                   cd: project,
                   env: [
                     {"GYM_INTEL_KUBE_NAMESPACE", namespace},
                     {"GYM_INTEL_KUBE_SECRETS_DIR", nil},
                     {"PATH", bin <> ":" <> System.fetch_env!("PATH")}
                   ],
                   stderr_to_stdout: true
                 )

        assert output =~ "workloads prepared"
        args = File.read!(Path.join(project, "app-settings.args")) |> String.split("\n")
        assert "--from-literal=CSV_IMPORT_RECOVERY_ENABLED=#{enabled}" in args
        assert "--from-literal=SOURCE_CHECKS_ENABLED=#{enabled}" in args
      end
    end
  end

  test "unknown backend refuses backup and update without contacting Docker" do
    for script <- ["scripts/backup-database.sh", "scripts/update-dashboard.sh"] do
      assert {output, 2} =
               System.cmd("sh", [script],
                 env: [{"GYM_INTEL_BACKEND", "unexpected"}],
                 stderr_to_stdout: true
               )

      assert output =~ "Unknown execution backend"
    end
  end
end
