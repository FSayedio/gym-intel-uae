Code.require_file("scripts/recovery/dashboard_probe.exs")

defmodule GymIntel.RecoveryDashboardProbeTest do
  use ExUnit.Case, async: true
  alias GymIntel.Recovery.DashboardProbe

  test "matching recovered query rows prove the expected synthetic price" do
    chart = [%{"Gym" => "TEST ONLY", "Advertised charge" => 199.0}]
    conditions = [%{"Gym" => "TEST ONLY", "Branch" => "TEST BRANCH"}]
    assert DashboardProbe.validate_rows!(chart, conditions, gym: "TEST ONLY", price: "199") == 1
    assert DashboardProbe.validate_rows!([], []) == 0
  end

  test "wrong synthetic prices or missing expected offers fail" do
    for chart <- [[], [%{"Gym" => "TEST ONLY", "Advertised charge" => 198.0}]] do
      conditions = Enum.map(chart, &Map.take(&1, ["Gym"]))

      assert_raise RuntimeError, ~r/Synthetic recovered offer/, fn ->
        DashboardProbe.validate_rows!(chart, conditions, gym: "TEST ONLY", price: "199")
      end
    end
  end

  test "matching names are not sufficient when a price is not numeric" do
    assert_raise RuntimeError, ~r/do not agree/, fn ->
      DashboardProbe.validate_rows!(
        [%{"Gym" => "TEST ONLY", "Advertised charge" => "Unknown"}],
        [%{"Gym" => "TEST ONLY"}]
      )
    end
  end

  test "chart and conditions must select the same offers in the same order" do
    assert_raise RuntimeError, ~r/do not agree/, fn ->
      DashboardProbe.validate_rows!(
        [%{"Gym" => "TEST A", "Advertised charge" => 199}],
        [%{"Gym" => "TEST B"}]
      )
    end
  end

  test "query errors and malformed column vectors cannot pass as recovered rows" do
    frame = %{
      "schema" => %{"fields" => [%{"name" => "Gym"}, %{"name" => "Advertised charge"}]},
      "data" => %{"values" => [["TEST ONLY"], [199.0]]}
    }

    good = %{"status" => 200, "frames" => [frame]}
    assert DashboardProbe.rows!(good) == [%{"Gym" => "TEST ONLY", "Advertised charge" => 199.0}]

    for bad <- [Map.put(good, "status", 500), Map.put(good, "error", "TEST FAILURE")] do
      assert_raise RuntimeError, ~r/query failed/, fn -> DashboardProbe.rows!(bad) end
    end

    bad_frame = put_in(frame, ["data", "values"], [["TEST ONLY"], []])

    assert_raise RuntimeError, ~r/Malformed/, fn ->
      DashboardProbe.rows!(%{"status" => 200, "frames" => [bad_frame]})
    end
  end

  test "recovered panel queries must match the committed dashboard" do
    expected = "grafana/dashboards/memberships.json" |> File.read!() |> Jason.decode!()
    response = %{"meta" => %{"provisioned" => true}, "dashboard" => expected}
    assert length(DashboardProbe.validate_dashboard!(response, expected)) == 2

    changed =
      update_in(response, ["dashboard", "panels"], fn panels ->
        Enum.map(panels, fn panel ->
          if panel["id"] == 2, do: Map.put(panel, "targets", []), else: panel
        end)
      end)

    assert_raise RuntimeError, ~r/query configuration differs/, fn ->
      DashboardProbe.validate_dashboard!(changed, expected)
    end

    assert_raise RuntimeError, ~r/identity\/provisioning differs/, fn ->
      DashboardProbe.validate_dashboard!(
        put_in(response, ["meta", "provisioned"], false),
        expected
      )
    end
  end
end
