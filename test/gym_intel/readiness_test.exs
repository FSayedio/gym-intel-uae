Code.require_file("scripts/readiness/workload.exs")

defmodule GymIntel.ReadinessTest do
  use ExUnit.Case, async: true
  alias GymIntel.{MembershipCSV, Readiness.Workload}

  test "bounded synthetic batches parse and overlap in exactly 500 observations" do
    first_csv = Workload.csv(1..1000)
    second_csv = Workload.csv(501..1500)
    assert byte_size(first_csv) < MembershipCSV.max_bytes()
    assert byte_size(second_csv) < MembershipCSV.max_bytes()
    assert {:ok, first} = MembershipCSV.parse(first_csv)
    assert {:ok, second} = MembershipCSV.parse(second_csv)
    assert length(first) == 1000
    assert length(second) == 1000
    assert Enum.drop(first, 500) == Enum.take(second, 500)
    assert length(Enum.uniq(first ++ second)) == 1500
    refute first_csv == second_csv
    assert Enum.all?(first ++ second, &String.starts_with?(&1.brand_name, "TEST ONLY WORKLOAD "))
  end

  test "interruption input is one exact synthetic offer" do
    assert {:ok, [offer]} = MembershipCSV.parse(Workload.interrupted_csv())
    assert offer.brand_name == "TEST ONLY INTERRUPTED"
    assert Decimal.equal?(offer.advertised_price_aed, "199")
  end

  test "fixture helper refuses non-fixture database and output directory" do
    assert_raise RuntimeError, ~r/generated test database/, fn -> Workload.run(:recover) end
    assert_raise RuntimeError, fn -> Workload.write_inputs() end
  end

  test "query plan summaries contain structural metrics, not SQL or data filters" do
    plan = %{
      "Node Type" => "Sort",
      "Actual Rows" => 1502,
      "Plans" => [
        %{"Node Type" => "Seq Scan", "Relation Name" => "memberships", "Filter" => "DO NOT PRINT"}
      ]
    }

    assert Workload.plan_nodes(plan) == [
             %{"Node Type" => "Sort", "Actual Rows" => 1502},
             %{"Node Type" => "Seq Scan", "Relation Name" => "memberships"}
           ]
  end

  test "entrypoints reject invalid scope before secret files or Docker are needed" do
    for arguments <- [["unexpected"], ["--target", "gym_intel_dev"]] do
      {_output, 2} =
        System.cmd("sh", ["scripts/verify-readiness.sh" | arguments], stderr_to_stdout: true)
    end

    {output, 2} =
      System.cmd("sh", ["scripts/verify-release.sh", "--readiness"],
        env: [{"READINESS_RUN", nil}],
        stderr_to_stdout: true
      )

    assert output =~ "isolated verify-readiness.sh wrapper"
  end

  test "the test gate is released only after worker exit and before waiting for rollback" do
    script = File.read!("scripts/readiness/rehearse.sh")
    {dead_worker, _} = :binary.match(script, "'false 137'")
    {release_gate, _} = :binary.match(script, "docker rm -f \"$readiness_holder\"")
    {terminate_gate, _} = :binary.match(script, "SELECT pg_terminate_backend(pid,5000)")
    {rollback_wait, _} = :binary.match(script, "readiness_phase=verify-rollback")
    assert dead_worker < release_gate
    assert release_gate < terminate_gate
    assert terminate_gate < rollback_wait
    assert script =~ "application_name='readiness_gate_$run_id' AND usename='$owner_user'"
  end
end
