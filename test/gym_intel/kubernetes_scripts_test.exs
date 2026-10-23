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
