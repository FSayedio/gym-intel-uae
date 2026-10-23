defmodule GymIntel.Recovery.DashboardProbe do
  @moduledoc false
  @uid "gym-intel-memberships"

  def run do
    {:ok, _} = Application.ensure_all_started(:inets)
    wait_ready(60)
    expected = "/expected-dashboard.json" |> File.read!() |> :json.decode()
    dashboard = request!(:get, "/api/dashboards/uid/gym-intel-offers")
    panels = validate_dashboard!(dashboard, expected)
    datasource = request!(:get, "/api/datasources/uid/#{@uid}")

    unless datasource["user"] == "gym_intel_grafana" and
             datasource["url"] == "postgres:5432" and
             datasource["secureJsonFields"]["password"] == true do
      raise "Recovered datasource does not use the expected reader connection"
    end

    unless request!(:get, "/api/datasources/uid/#{@uid}/health")["status"] == "OK" do
      raise "Recovered datasource health failed"
    end

    [chart, conditions] = Enum.map(panels, &query_panel!/1)

    count =
      validate_rows!(chart, conditions,
        gym: System.get_env("RECOVERY_EXPECTED_GYM", ""),
        price: System.get_env("RECOVERY_EXPECTED_PRICE", "")
      )

    password = "/run/secrets/grafana_admin_password" |> File.read!() |> String.trim_trailing("\n")
    if password == "", do: raise("Fresh admin credential is empty")
    authorization = ~c"Basic " ++ String.to_charlist(Base.encode64("admin:" <> password))
    user = request!(:get, "/api/user", nil, [{~c"authorization", authorization}])

    unless user["login"] == "admin" and user["isGrafanaAdmin"] == true do
      raise "Fresh administrator login was not verified"
    end

    IO.puts(
      "PASS: Git-provisioned Grafana, reader datasource, both panel queries (#{count} offers), fresh admin login"
    )
  end

  def validate_dashboard!(response, expected) do
    dashboard = response["dashboard"]

    unless response["meta"]["provisioned"] == true and
             dashboard["uid"] == expected["uid"] and
             dashboard["title"] == expected["title"] and
             dashboard["refresh"] == expected["refresh"] and
             dashboard["editable"] == false do
      raise "Recovered dashboard identity/provisioning differs from Git"
    end

    Enum.map([2, 3], fn id ->
      panel = Enum.find(dashboard["panels"], &(&1["id"] == id))
      source = Enum.find(expected["panels"], &(&1["id"] == id))

      unless panel && source && panel["type"] == source["type"] &&
               panel["targets"] == source["targets"] do
        raise "Recovered panel/query configuration differs from Git"
      end

      panel
    end)
  end

  def rows!(result) do
    unless result["status"] == 200 and result["error"] in [nil, ""] and
             is_list(result["frames"]) do
      raise "Recovered panel query failed"
    end

    Enum.flat_map(result["frames"], fn frame ->
      names = Enum.map(frame["schema"]["fields"], & &1["name"])
      columns = frame["data"]["values"]

      unless is_list(columns) and length(names) == length(columns) and
               Enum.all?(columns, &is_list/1) and
               length(Enum.uniq(Enum.map(columns, &length/1))) <= 1 do
        raise "Malformed recovered query frame"
      end

      columns |> Enum.zip() |> Enum.map(&Map.new(Enum.zip(names, Tuple.to_list(&1))))
    end)
  end

  def validate_rows!(chart, conditions, opts \\ []) do
    chart_gyms = Enum.map(chart, &Map.fetch!(&1, "Gym"))
    condition_gyms = Enum.map(conditions, &Map.fetch!(&1, "Gym"))

    unless chart_gyms == condition_gyms and
             Enum.all?(chart, &is_number(&1["Advertised charge"])) do
      raise "Recovered chart and conditions do not agree"
    end

    if Keyword.get(opts, :gym, "") != "" do
      expected_price =
        case Float.parse(Keyword.get(opts, :price, "")) do
          {price, ""} -> price
          _ -> raise "Expected synthetic fixture price is invalid"
        end

      unless chart_gyms == [Keyword.fetch!(opts, :gym)] and
               Map.fetch!(hd(chart), "Advertised charge") == expected_price do
        raise "Synthetic recovered offer differs from the expected fixture"
      end
    end

    length(chart)
  end

  defp query_panel!(panel) do
    queries =
      Enum.map(panel["targets"], fn target ->
        Map.merge(target, %{"intervalMs" => 1000, "maxDataPoints" => 1000})
      end)

    response =
      request!(:post, "/api/ds/query", %{"queries" => queries, "from" => "0", "to" => "now"})

    results = response["results"]
    Enum.each(queries, &rows!(Map.fetch!(results, &1["refId"])))
    rows!(Map.fetch!(results, "A"))
  end

  defp wait_ready(0), do: raise("Replacement Grafana did not become ready")

  defp wait_ready(remaining) do
    ready =
      try do
        request!(:get, "/api/health")["database"] == "ok"
      rescue
        _ -> false
      end

    unless ready do
      Process.sleep(500)
      wait_ready(remaining - 1)
    end
  end

  defp request!(method, path, body \\ nil, headers \\ []) do
    url = String.to_charlist("http://grafana:3000" <> path)

    request =
      if method == :get do
        {url, headers}
      else
        {url, headers, ~c"application/json", :json.encode(body)}
      end

    case :httpc.request(method, request, [timeout: 5000, connect_timeout: 1000],
           body_format: :binary
         ) do
      {:ok, {{_, 200, _}, _, text}} -> :json.decode(text)
      _ -> raise "Replacement Grafana request failed at #{path}"
    end
  end
end
