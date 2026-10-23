defmodule GymIntel.DashboardQueriesDatabaseTest do
  use ExUnit.Case, async: false
  alias GymIntel.{Membership, Repo}
  @moduletag :database

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    Repo.delete_all("membership_notes")
    Repo.delete_all(Membership)
    :ok
  end

  defp dashboard, do: Jason.decode!(File.read!("grafana/dashboards/memberships.json"))
  defp panel, do: Enum.find(dashboard()["panels"], &(&1["type"] == "barchart"))
  defp conditions_panel, do: Enum.find(dashboard()["panels"], &(&1["type"] == "table"))

  defp offer(brand, changes \\ %{}) do
    attrs = %{
      brand_name: brand,
      branch_name: "Test branch",
      plan_name: "Test monthly plan",
      access_scope: "single_branch",
      advertised_price_aed: Decimal.new("200"),
      billing_period_months: 1,
      minimum_commitment_months: 0,
      source_url: "https://example.com/test-only",
      observed_on: ~D[2026-10-22],
      notes: "SYNTHETIC DASHBOARD TEST ONLY"
    }

    Repo.insert!(struct(Membership, Map.merge(attrs, changes)))
  end

  defp query_rows(panel) do
    result = Repo.query!(hd(panel["targets"])["rawSql"])
    Enum.map(result.rows, &Map.new(Enum.zip(result.columns, &1)))
  end

  defp rows do
    graph_rows = query_rows(panel())
    table_rows = query_rows(conditions_panel())

    identity = [
      "Gym",
      "Branch",
      "Original plan",
      "Observed",
      "Source",
      "Supporting sources"
    ]

    assert Enum.map(graph_rows, &Map.take(&1, identity)) ==
             Enum.map(table_rows, &Map.take(&1, identity))

    graph_rows
  end

  test "one vertical graph with a compact conditions table and no filter variables" do
    assert Enum.map(dashboard()["panels"], & &1["type"]) == ["text", "barchart", "table"]
    assert panel()["type"] == "barchart"
    assert panel()["options"]["orientation"] == "vertical"
    assert panel()["options"]["xField"] == "Category"
    assert dashboard()["templating"]["list"] == []
    assert dashboard()["timepicker"]["hidden"]

    assert conditions_panel()["gridPos"]["y"] ==
             panel()["gridPos"]["y"] + panel()["gridPos"]["h"]
  end

  test "graph and table share the exact selection CTEs and order" do
    graph_sql = hd(panel()["targets"])["rawSql"]
    table_sql = hd(conditions_panel()["targets"])["rawSql"]

    assert hd(String.split(graph_sql, "\nSELECT brand_name ||")) ==
             hd(String.split(table_sql, "\nSELECT brand_name ||"))

    assert String.ends_with?(table_sql, "ORDER BY brand_name, branch_name, plan_name")
  end

  test "table has exactly five visible columns and hidden evidence for source links" do
    table = conditions_panel()
    result = Repo.query!(hd(table["targets"])["rawSql"])
    [gym, hidden] = table["fieldConfig"]["overrides"]
    assert hidden["properties"] == [%{"id" => "custom.hidden", "value" => true}]
    hidden_pattern = Regex.compile!(hidden["matcher"]["options"])

    assert Enum.reject(result.columns, &Regex.match?(hidden_pattern, &1)) == [
             "Gym",
             "Branch",
             "Minimum commitment",
             "Joining / admin fees",
             "Payment / renewal / VAT"
           ]

    [link] = hd(gym["properties"])["value"]
    assert link["title"] == ~s(Official source · checked ${__data.fields["Observed"]})
    assert link["url"] == ~s(${__data.fields["Source"]})
    assert link["targetBlank"]
    assert table["fieldConfig"]["defaults"]["custom"]["cellOptions"]["wrapText"]
    refute table["fieldConfig"]["defaults"]["custom"]["filterable"]
  end

  test "a visible note discloses differing dates, unknowns and unresolved Warehouse scope" do
    note = Enum.find(dashboard()["panels"], &(&1["type"] == "text"))
    assert note["gridPos"]["y"] < panel()["gridPos"]["y"]

    for warning <- [
          "not live quotes or equivalent memberships",
          "Dates and terms differ",
          "Unknown is not zero",
          "membership price only",
          "historical access scope remains unresolved"
        ] do
      assert note["options"]["content"] =~ warning
    end
  end

  test "only the membership price is numeric and currency appears once on the axis" do
    offer("Test gym")
    result = Repo.query!(hd(panel()["targets"])["rawSql"])
    assert Enum.count(hd(result.rows), &is_number/1) == 1
    assert panel()["fieldConfig"]["defaults"]["unit"] == "none"
    assert panel()["fieldConfig"]["defaults"]["custom"]["axisLabel"] == "AED per month"
    assert panel()["fieldConfig"]["defaults"]["min"] == 0
    assert panel()["options"]["showValue"] == "always"
    assert panel()["options"]["legend"]["showLegend"]
    assert panel()["options"]["legend"]["placement"] == "right"
    assert panel()["fieldConfig"]["defaults"]["color"]["mode"] == "palette-classic"
  end

  test "real CSVs give four bars while preserving the six historical observations" do
    for path <- ["data/memberships.csv", "data/memberships-2026-10-22.csv"] do
      {:ok, memberships} = GymIntel.MembershipCSV.read(path)
      for membership <- memberships, do: Repo.insert!(membership)
    end

    assert Repo.aggregate(Membership, :count) == 6
    result = rows()

    assert Enum.map(result, &{&1["Gym"], &1["Advertised charge"], &1["Observed"]}) == [
             {"GymNation", 209.0, "2026-10-22"},
             {"La Maison de la Masse", 1500.0, "2026-10-22"},
             {"PureGym", 199.0, "2026-10-22"},
             {"The Warehouse Gym", 363.0, "2026-09-12"}
           ]

    maison = Enum.find(result, &(&1["Gym"] == "La Maison de la Masse"))

    for text <- [
          "Minimum commitment: No minimum",
          "VAT: Unknown",
          "Payment: Unknown",
          "Renewal: Unknown",
          "Joining: Unknown",
          "Admin: Unknown"
        ] do
      assert maison["Terms"] =~ text
    end

    assert panel()["description"] =~ "Warehouse's historical access scope remains unresolved"

    [gymnation, maison, puregym, warehouse] = query_rows(conditions_panel())
    assert gymnation["Branch"] == "Downtown Dubai"
    assert gymnation["Minimum commitment"] == "12 months"
    assert gymnation["Joining / admin fees"] == "Joining: AED 199; Admin: AED 30"

    assert gymnation["Payment / renewal / VAT"] ==
             "Payment: Recurring; Renewal: Automatic; Membership VAT: Included"

    assert maison["Minimum commitment"] == "No minimum"
    assert maison["Joining / admin fees"] == "Joining: Unknown; Admin: Unknown"

    assert maison["Payment / renewal / VAT"] ==
             "Payment: Unknown; Renewal: Unknown; Membership VAT: Unknown"

    assert puregym["Minimum commitment"] == "No minimum"
    assert puregym["Joining / admin fees"] == "Joining: AED 89; Admin: Unknown"
    assert warehouse["Minimum commitment"] == "3 months"
    assert warehouse["Observed"] == "2026-09-12"
  end

  test "new recorded gyms appear without a hardcoded pool or three-bar limit" do
    for brand <- ["Alpha", "Bravo", "Charlie", "Delta", "Echo", "Foxtrot"], do: offer(brand)

    assert Enum.map(rows(), & &1["Gym"]) == [
             "Alpha",
             "Bravo",
             "Charlie",
             "Delta",
             "Echo",
             "Foxtrot"
           ]
  end

  test "latest observation is chosen separately for each offer" do
    offer("Alpha", %{observed_on: ~D[2026-10-20], advertised_price_aed: Decimal.new("100")})
    offer("Alpha", %{advertised_price_aed: Decimal.new("250")})
    offer("Bravo", %{observed_on: ~D[2026-10-21], advertised_price_aed: Decimal.new("300")})

    assert Enum.map(rows(), &{&1["Gym"], &1["Advertised charge"]}) == [
             {"Alpha", 250.0},
             {"Bravo", 300.0}
           ]
  end

  test "newer unknown price never falls back to an older known price" do
    offer("Alpha", %{observed_on: ~D[2026-10-20]})
    offer("Alpha", %{advertised_price_aed: nil})
    assert rows() == []
  end

  test "newer annual observation does not masquerade as the older monthly offer" do
    offer("Alpha", %{observed_on: ~D[2026-10-20]})
    offer("Alpha", %{billing_period_months: 12, advertised_price_aed: Decimal.new("2400")})
    assert rows() == []
  end

  test "annual and multi-branch prices do not enter the single-branch monthly view" do
    offer("Monthly")
    offer("Annual", %{billing_period_months: 12})
    offer("Multi", %{access_scope: "multiple_named_branches"})
    assert Enum.map(rows(), & &1["Gym"]) == ["Monthly"]
  end

  test "corroborating sources yield one bar while internal notes stay out of dashboard data" do
    offer("Alpha")
    offer("Alpha", %{source_url: "https://example.com/second", notes: "Second synthetic note"})
    [row] = rows()
    assert row["Advertised charge"] == 200.0
    assert row["Supporting sources"] =~ "https://example.com/test-only"
    assert row["Supporting sources"] =~ "https://example.com/second"
    refute Map.has_key?(row, "Source notes")
    assert %{rows: [[2]]} = Repo.query!("SELECT count(*) FROM membership_notes")
  end

  test "conflicting latest prices do not select an arbitrary minimum" do
    offer("Alpha")
    offer("Alpha", %{advertised_price_aed: Decimal.new("999")})
    assert rows() == []
  end

  test "conflicting terms including known plus unknown are not silently collapsed" do
    for changes <- [
          %{minimum_commitment_months: 12},
          %{minimum_commitment_months: nil},
          %{joining_fee_aed: Decimal.new("0")},
          %{admin_fee_aed: Decimal.new("30")},
          %{payment_structure: "recurring"},
          %{renewal_policy: "automatic"},
          %{price_vat_status: "included"},
          %{access_scope: "multiple_named_branches"}
        ] do
      Repo.delete_all("membership_notes")
      Repo.delete_all(Membership)
      offer("Alpha")
      offer("Alpha", changes)
      assert rows() == []
    end
  end

  test "zero and unknown commitments and fees stay distinct without hiding all offers" do
    offer("Alpha")
    offer("Bravo", %{minimum_commitment_months: nil})
    offer("Charlie", %{joining_fee_aed: Decimal.new("0"), admin_fee_aed: Decimal.new("0")})
    [alpha, bravo, charlie] = rows()
    assert alpha["Terms"] =~ "Minimum commitment: No minimum"
    assert alpha["Terms"] =~ "Joining: Unknown"
    assert bravo["Terms"] =~ "Minimum commitment: Unknown"
    assert charlie["Terms"] =~ "Joining: AED 0"
    assert charlie["Terms"] =~ "Admin: AED 0"
    [alpha, bravo, charlie] = query_rows(conditions_panel())
    assert alpha["Minimum commitment"] == "No minimum"
    assert bravo["Minimum commitment"] == "Unknown"
    assert alpha["Joining / admin fees"] == "Joining: Unknown; Admin: Unknown"
    assert charlie["Joining / admin fees"] == "Joining: AED 0; Admin: AED 0"
  end

  test "table translates supported classifications without inventing defaults" do
    offer("Alpha", %{
      payment_structure: "prepaid_term",
      renewal_policy: "non_automatic",
      price_vat_status: "excluded",
      minimum_commitment_months: 1
    })

    [_] = rows()
    [row] = query_rows(conditions_panel())
    assert row["Minimum commitment"] == "1 month"

    assert row["Payment / renewal / VAT"] ==
             "Payment: Prepaid term; Renewal: Not automatic; Membership VAT: Excluded"
  end

  test "upfront fees are disclosed separately and never added to the monthly bar" do
    offer("Alpha", %{
      advertised_price_aed: Decimal.new("209"),
      joining_fee_aed: Decimal.new("199"),
      admin_fee_aed: Decimal.new("30"),
      price_vat_status: "included",
      payment_structure: "recurring",
      renewal_policy: "automatic"
    })

    [row] = rows()
    assert row["Advertised charge"] == 209.0

    for text <- [
          "Joining: AED 199",
          "Admin: AED 30",
          "VAT: included",
          "Payment: Recurring",
          "Renewal: Automatic"
        ] do
      assert row["Terms"] =~ text
    end
  end

  test "multiple offers for one brand have branch and original-plan labels" do
    offer("Alpha", %{branch_name: "North", plan_name: "Core"})
    offer("Alpha", %{branch_name: "South", plan_name: "Flex"})
    assert Enum.map(rows(), & &1["Gym"]) == ["Alpha · North · Core", "Alpha · South · Flex"]
    assert Enum.map(rows(), & &1["Original plan"]) == ["Core", "Flex"]
  end

  test "graph is alphabetical rather than implying a cheapest or best-gym ranking" do
    offer("Alpha", %{advertised_price_aed: Decimal.new("1500")})
    offer("Bravo", %{advertised_price_aed: Decimal.new("199")})
    assert Enum.map(rows(), & &1["Gym"]) == ["Alpha", "Bravo"]
    assert panel()["description"] =~ "not a cheapest or best-gym ranking"
  end

  test "public metadata retains source and identity but not internal note history" do
    offer("Alpha", %{notes: "Example uncertainty; do not omit"})
    [row] = rows()
    assert row["Source"] == "https://example.com/test-only"
    assert row["Observed"] == "2026-10-22"
    assert row["Branch"] == "Test branch"
    assert row["Original plan"] == "Test monthly plan"
    refute Map.has_key?(row, "Source notes")

    assert %{rows: [["Example uncertainty; do not omit"]]} =
             Repo.query!("SELECT notes FROM membership_notes")
  end

  test "bar links retain dates terms and source alongside the conditions table" do
    [source, terms] = panel()["fieldConfig"]["defaults"]["links"]
    assert source["title"] =~ "Observed"
    assert source["url"] == "$" <> "{__field.labels.Source}"
    assert terms["title"] == "$" <> "{__field.labels.Terms}"
    assert terms["url"] == source["url"]
    assert source["targetBlank"]
    assert panel()["description"] =~ "Unknown is not zero"
  end

  test "empty database yields no bars instead of an invented zero" do
    assert rows() == []
    assert panel()["fieldConfig"]["defaults"]["noValue"] =~ "No eligible"
  end

  test "each gym becomes a named series while metadata remains in field labels" do
    [rows_to_fields, concatenate] = panel()["transformations"]
    assert rows_to_fields["id"] == "rowsToFields"
    assert rows_to_fields["filter"] == %{"id" => "byRefId", "options" => "A"}
    assert concatenate["id"] == "concatenate"
    assert concatenate["options"]["frameNameMode"] == "drop"
    assert panel()["fieldConfig"]["defaults"]["displayName"] == "$" <> "{__field.name}"
  end

  test "the chart category is blank so gym names appear in the legend not below bars" do
    category = Enum.find(panel()["targets"], &(&1["refId"] == "B"))
    # Zero-width text is neither empty nor numeric whitespace; Grafana must not
    # substitute its no-value message or coerce the bottom category to 0.
    assert Repo.query!(category["rawSql"]).rows == [[<<0x200B::utf8>>]]
    assert Enum.map(panel()["targets"], & &1["refId"]) == ["A", "B"]

    category_override =
      Enum.find(panel()["fieldConfig"]["overrides"], &(&1["matcher"]["options"] == "Category"))

    blank_label = Enum.find(category_override["properties"], &(&1["id"] == "noValue"))
    assert String.trim(blank_label["value"]) == ""
  end
end
