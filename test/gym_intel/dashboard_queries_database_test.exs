defmodule GymIntel.DashboardQueriesDatabaseTest do
  use ExUnit.Case, async: false

  alias GymIntel.{Membership, Repo}

  @moduletag :database

  @cohort [
    {"GymNation", "Downtown Dubai", "Core", 209},
    {"PureGym", "Dubai Al Barsha", "CORE", 199},
    {"The Warehouse Gym", "IBN Battuta Mall", "Light Monthly", 363}
  ]

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    Repo.delete_all(Membership)
    :ok
  end

  defp offer(index, date, changes \\ %{}) do
    {brand, branch, plan, price} = Enum.at(@cohort, index)

    attrs = %{
      brand_name: brand,
      branch_name: branch,
      plan_name: plan,
      access_scope: "single_branch",
      advertised_price_aed: Decimal.new(price),
      billing_period_months: 1,
      payment_structure: "recurring",
      renewal_policy: "automatic",
      price_vat_status: "included",
      source_url: "https://example.com/test-only",
      observed_on: date,
      notes: "SYNTHETIC DASHBOARD TEST ONLY"
    }

    Repo.insert!(struct(Membership, Map.merge(attrs, changes)))
  end

  defp complete(date, offset \\ 0) do
    for {{_brand, _branch, _plan, price}, index} <- Enum.with_index(@cohort) do
      offer(index, date, %{advertised_price_aed: Decimal.new(price + offset)})
    end
  end

  defp dashboard do
    Jason.decode!(File.read!("grafana/dashboards/memberships.json"))
  end

  defp panel_query(
         panel_id,
         variables \\ %{}
       ) do
    panel = Enum.find(dashboard()["panels"], &(&1["id"] == panel_id))

    # Mirror Grafana's sqlstring interpolation: values are quoted, not raw SQL.
    sql =
      %{
        "access_scope" => "single_branch",
        "commitment" => "0",
        "payment_structure" => "recurring",
        "renewal_policy" => "automatic",
        "price_vat_status" => "included"
      }
      |> Map.merge(variables)
      |> Enum.reduce(hd(panel["targets"])["rawSql"], fn {name, value}, sql ->
        quoted = "'" <> String.replace(value, "'", "''") <> "'"
        String.replace(sql, "${#{name}:sqlstring}", quoted)
      end)

    Repo.query!(sql)
  end

  defp chart do
    panel_query(2)
  end

  defp evidence do
    result = panel_query(3)
    Enum.map(result.rows, &Map.new(Enum.zip(result.columns, &1)))
  end

  defp comparison_status do
    panel_query(5).rows |> hd() |> hd()
  end

  defp prices do
    for row <- chart().rows, do: {Enum.at(row, 0), Enum.at(row, 1)}
  end

  defp expected(offset \\ 0) do
    for {brand, _branch, _plan, price} <- @cohort, do: {brand, (price + offset) * 1.0}
  end

  test "shows a complete same-date monthly comparison" do
    complete(~D[2026-09-12])
    assert prices() == expected()
  end

  test "a newer annual observation does not erase the complete monthly comparison" do
    complete(~D[2026-09-12])
    offer(0, ~D[2026-09-13], %{billing_period_months: 12})
    assert prices() == expected()
  end

  test "a partial monthly refresh preserves the last complete date" do
    complete(~D[2026-09-12])
    offer(0, ~D[2026-09-13], %{advertised_price_aed: Decimal.new(999)})
    assert prices() == expected()
  end

  test "a newer complete date replaces the older comparison without mixing dates" do
    complete(~D[2026-09-12])
    complete(~D[2026-09-13], 10)
    assert prices() == expected(10)
  end

  test "an unknown price cannot make a collection complete" do
    complete(~D[2026-09-12])
    offer(0, ~D[2026-09-13])
    offer(1, ~D[2026-09-13])

    offer(2, ~D[2026-09-13], %{
      advertised_price_aed: nil,
      minimum_commitment_months: 0
    })

    assert prices() == expected()
  end

  test "no complete date produces no comparison instead of a partial ranking" do
    offer(0, ~D[2026-09-12])
    offer(1, ~D[2026-09-13])
    assert prices() == []
  end

  test "an unselected newer plan does not replace the selected offers" do
    complete(~D[2026-09-12])
    offer(0, ~D[2026-09-13], %{plan_name: "Different plan"})
    assert prices() == expected()
  end

  test "conflicting prices for one offer do not choose an arbitrary value" do
    complete(~D[2026-09-12])
    complete(~D[2026-09-13], 10)
    offer(0, ~D[2026-09-13], %{advertised_price_aed: Decimal.new(999)})
    assert prices() == expected()
  end

  test "duplicate evidence for the same price does not multiply bars" do
    complete(~D[2026-09-12])
    offer(0, ~D[2026-09-12], %{notes: "A second test-only evidence note"})
    assert prices() == expected()
  end

  test "chart results disclose the selected observation date" do
    complete(~D[2026-09-12])
    offer(0, ~D[2026-09-13])
    result = chart()
    assert "Observed" in result.columns
    observed_index = Enum.find_index(result.columns, &(&1 == "Observed"))
    assert Enum.map(result.rows, &Enum.at(&1, observed_index)) == List.duplicate("2026-09-12", 3)
  end

  test "normalization describes conditions without replacing official plan names" do
    complete(~D[2026-09-12])
    rows = evidence()
    assert Enum.map(rows, & &1["Original plan name"]) == ["Core", "CORE", "Light Monthly"]
    assert Enum.map(rows, & &1["Access"]) == List.duplicate("Single branch", 3)
    assert Enum.map(rows, & &1["Payment covers"]) == List.duplicate("1 month", 3)
    assert Enum.map(rows, & &1["Minimum commitment"]) == List.duplicate("Unknown", 3)
  end

  test "evidence distinguishes documented no minimum from unknown commitment" do
    offer(0, ~D[2026-09-12], %{minimum_commitment_months: 0})
    offer(1, ~D[2026-09-12])
    offer(2, ~D[2026-09-12], %{minimum_commitment_months: 3})

    assert Enum.map(evidence(), & &1["Minimum commitment"]) == [
             "No minimum commitment",
             "Unknown",
             "3 months"
           ]
  end

  test "unknown price observations stay visible and are never displayed as zero" do
    complete(~D[2026-09-12])
    offer(0, ~D[2026-09-13], %{advertised_price_aed: nil, minimum_commitment_months: 12})
    [latest | older] = evidence()
    assert latest["Advertised price AED"] == nil
    assert latest["Observed"] == "2026-09-13"
    assert length(older) == 3
    assert prices() == expected()
  end

  test "annual prices disclose their native billing period instead of being called monthly" do
    complete(~D[2026-09-12])

    offer(0, ~D[2026-09-13], %{advertised_price_aed: Decimal.new(2400), billing_period_months: 12})

    [annual | _] = evidence()
    assert annual["Payment covers"] == "12 months"
    assert annual["Advertised price AED"] == 2400.0
    refute Map.has_key?(annual, "AED/month")
    assert prices() == expected()
  end

  test "all observation dates remain inspectable during a partial refresh" do
    complete(~D[2026-09-12])
    offer(0, ~D[2026-09-13])

    assert Enum.frequencies_by(evidence(), & &1["Observed"]) == %{
             "2026-09-12" => 3,
             "2026-09-13" => 1
           }
  end

  test "all supported access categories use readable labels in evidence" do
    offer(0, ~D[2026-09-12])
    offer(1, ~D[2026-09-12], %{access_scope: "multiple_named_branches"})
    offer(2, ~D[2026-09-12], %{access_scope: "all_uae_branches"})

    assert Enum.map(evidence(), & &1["Access"]) == [
             "Single branch",
             "Specified branches",
             "All operator UAE branches"
           ]
  end

  test "unknown commitments cannot qualify as no minimum commitment" do
    complete(~D[2026-09-12])
    assert panel_query(4).rows == []
    assert comparison_status() =~ "Not enough comparable offers — 0 gyms match"
    assert prices() == expected()
  end

  test "a single matching gym is not presented as a comparison" do
    offer(0, ~D[2026-09-12], %{minimum_commitment_months: 12})
    offer(1, ~D[2026-09-12], %{minimum_commitment_months: 0})
    offer(2, ~D[2026-09-12], %{minimum_commitment_months: 3})
    assert panel_query(4).rows == []
    assert comparison_status() =~ "Not enough comparable offers — 1 gym matches"
  end

  test "two brands with matching verified dimensions qualify despite different plan names" do
    offer(0, ~D[2026-09-12], %{minimum_commitment_months: 0})
    offer(1, ~D[2026-09-12], %{minimum_commitment_months: 0})
    offer(2, ~D[2026-09-12], %{minimum_commitment_months: 3})

    assert panel_query(4).rows == [
             ["GymNation", 209.0, "2026-09-12"],
             ["PureGym", 199.0, "2026-09-12"]
           ]

    assert comparison_status() =~ "2 gyms match access and commitment"
    assert comparison_status() =~ "fees, tax rates, notice and benefits may differ"
  end

  test "commitment selection chooses the requested group rather than mixing durations" do
    offer(0, ~D[2026-09-12], %{minimum_commitment_months: 3})
    offer(1, ~D[2026-09-12], %{minimum_commitment_months: 0})
    offer(2, ~D[2026-09-12], %{minimum_commitment_months: 3})
    assert panel_query(4).rows == []
    result = panel_query(4, %{"access_scope" => "single_branch", "commitment" => "3"})

    assert result.rows == [
             ["GymNation", 209.0, "2026-09-12"],
             ["The Warehouse Gym", 363.0, "2026-09-12"]
           ]
  end

  test "conflicting commitment evidence disqualifies that offer instead of choosing a value" do
    for index <- 0..2, do: offer(index, ~D[2026-09-12], %{minimum_commitment_months: 0})
    offer(0, ~D[2026-09-12], %{minimum_commitment_months: 12})
    assert Enum.map(panel_query(4).rows, &hd/1) == ["PureGym", "The Warehouse Gym"]
  end

  test "known and unknown commitment evidence is not silently collapsed to known" do
    offer(0, ~D[2026-09-12], %{minimum_commitment_months: 0})
    offer(0, ~D[2026-09-12], %{minimum_commitment_months: nil})
    offer(1, ~D[2026-09-12], %{minimum_commitment_months: 0})
    offer(2, ~D[2026-09-12], %{minimum_commitment_months: 3})
    assert panel_query(4).rows == []
    assert comparison_status() =~ "1 gym matches"
  end

  test "conflicting access evidence does not qualify as single branch" do
    for index <- 0..2, do: offer(index, ~D[2026-09-12], %{minimum_commitment_months: 0})

    offer(0, ~D[2026-09-12], %{
      access_scope: "multiple_named_branches",
      minimum_commitment_months: 0
    })

    assert Enum.map(panel_query(4).rows, &hd/1) == ["PureGym", "The Warehouse Gym"]
  end

  test "duplicated evidence does not turn one gym into two qualifying gyms" do
    complete(~D[2026-09-12])
    offer(0, ~D[2026-09-12], %{minimum_commitment_months: 0})
    offer(0, ~D[2026-09-12], %{minimum_commitment_months: 0, notes: "Second synthetic note"})
    assert panel_query(4).rows == []
  end

  test "no complete date gives an explicit availability explanation" do
    offer(0, ~D[2026-09-12], %{minimum_commitment_months: 0})
    offer(1, ~D[2026-09-13], %{minimum_commitment_months: 0})
    assert panel_query(4).rows == []
    assert comparison_status() =~ "no complete monthly observation date"
  end

  test "filtered comparison preserves the overview date without mixing partial updates" do
    for index <- 0..2, do: offer(index, ~D[2026-09-12], %{minimum_commitment_months: 0})

    offer(0, ~D[2026-09-13], %{
      minimum_commitment_months: 0,
      advertised_price_aed: Decimal.new(999)
    })

    assert panel_query(4).rows ==
             Enum.map(expected(), fn {brand, price} -> [brand, price, "2026-09-12"] end)
  end

  test "filters are SQL string values rather than executable SQL" do
    complete(~D[2026-09-12])
    result = panel_query(4, %{"access_scope" => "single_branch", "commitment" => "0' OR '1'='1"})
    assert result.rows == []
  end

  test "commitment choices contain no minimum plus actual known values but not unknown" do
    offer(0, ~D[2026-09-12], %{minimum_commitment_months: 3})
    offer(1, ~D[2026-09-12])
    variable = Enum.find(dashboard()["templating"]["list"], &(&1["name"] == "commitment"))

    assert Repo.query!(variable["query"]).rows == [
             ["No minimum commitment", "0"],
             ["3 months", "3"]
           ]
  end

  test "comparison status selects text fields and does not mask missing query data as insufficient offers" do
    panel = Enum.find(dashboard()["panels"], &(&1["id"] == 5))
    assert panel["options"]["reduceOptions"]["fields"] == "/.*/"
    assert panel["fieldConfig"]["defaults"]["noValue"] =~ "unavailable"
    refute panel["fieldConfig"]["defaults"]["noValue"] =~ "Not enough comparable offers"
  end

  test "repeated evidence with consistent terms produces one bar per qualifying gym" do
    for index <- 0..2, do: offer(index, ~D[2026-09-12], %{minimum_commitment_months: 0})

    offer(0, ~D[2026-09-12], %{
      minimum_commitment_months: 0,
      notes: "Another synthetic source note"
    })

    assert length(panel_query(4).rows) == 3
    assert Enum.map(panel_query(4).rows, &hd/1) == ["GymNation", "PureGym", "The Warehouse Gym"]
  end

  test "a new complete price date with unknown terms does not backfill older commitments" do
    for index <- 0..2, do: offer(index, ~D[2026-09-12], %{minimum_commitment_months: 0})
    complete(~D[2026-09-13], 10)
    assert prices() == expected(10)
    assert panel_query(4).rows == []
    assert comparison_status() =~ "0 gyms match"
  end

  test "matching billing and commitment do not conceal different payment structures" do
    offer(0, ~D[2026-09-12], %{minimum_commitment_months: 0, payment_structure: "prepaid_term"})
    offer(1, ~D[2026-09-12], %{minimum_commitment_months: 0})
    offer(2, ~D[2026-09-12], %{minimum_commitment_months: 0})
    assert Enum.map(panel_query(4).rows, &hd/1) == ["PureGym", "The Warehouse Gym"]
    assert prices() == expected()
  end

  test "renewal policy is matched independently of payment structure" do
    offer(0, ~D[2026-09-12], %{minimum_commitment_months: 0, renewal_policy: "non_automatic"})
    offer(1, ~D[2026-09-12], %{minimum_commitment_months: 0})
    offer(2, ~D[2026-09-12], %{minimum_commitment_months: 0})
    assert Enum.map(panel_query(4).rows, &hd/1) == ["PureGym", "The Warehouse Gym"]
  end

  test "prepaid and non-automatic selectors choose their own verified group" do
    for index <- 0..1 do
      offer(index, ~D[2026-09-12], %{
        minimum_commitment_months: 1,
        payment_structure: "prepaid_term",
        renewal_policy: "non_automatic"
      })
    end

    offer(2, ~D[2026-09-12], %{minimum_commitment_months: 1})
    assert panel_query(4).rows == []

    result =
      panel_query(4, %{
        "commitment" => "1",
        "payment_structure" => "prepaid_term",
        "renewal_policy" => "non_automatic"
      })

    assert Enum.map(result.rows, &hd/1) == ["GymNation", "PureGym"]
    assert hd(evidence())["Payment structure"] == "Prepaid term"
    assert hd(evidence())["Renewal"] == "No automatic renewal"
  end

  test "unknown payment or renewal cannot qualify and is displayed as unknown" do
    offer(0, ~D[2026-09-12], %{minimum_commitment_months: 0, payment_structure: nil})
    offer(1, ~D[2026-09-12], %{minimum_commitment_months: 0, renewal_policy: nil})
    offer(2, ~D[2026-09-12], %{minimum_commitment_months: 0})
    assert panel_query(4).rows == []
    assert comparison_status() =~ "1 gym matches"
    [first, second, _third] = evidence()
    assert first["Payment structure"] == "Unknown"
    assert first["Renewal"] == "Automatic renewal"
    assert second["Payment structure"] == "Recurring payments"
    assert second["Renewal"] == "Unknown"
  end

  test "conflicting or known-plus-unknown payment evidence excludes an offer" do
    for value <- ["prepaid_term", nil] do
      Repo.delete_all(Membership)
      for index <- 0..2, do: offer(index, ~D[2026-09-12], %{minimum_commitment_months: 0})
      offer(0, ~D[2026-09-12], %{minimum_commitment_months: 0, payment_structure: value})
      assert Enum.map(panel_query(4).rows, &hd/1) == ["PureGym", "The Warehouse Gym"]
    end
  end

  test "conflicting or known-plus-unknown renewal evidence excludes an offer" do
    for value <- ["non_automatic", nil] do
      Repo.delete_all(Membership)
      for index <- 0..2, do: offer(index, ~D[2026-09-12], %{minimum_commitment_months: 0})
      offer(0, ~D[2026-09-12], %{minimum_commitment_months: 0, renewal_policy: value})
      assert Enum.map(panel_query(4).rows, &hd/1) == ["PureGym", "The Warehouse Gym"]
    end
  end

  test "a newer complete date cannot borrow older payment or renewal evidence" do
    for index <- 0..2, do: offer(index, ~D[2026-09-12], %{minimum_commitment_months: 0})

    for index <- 0..2 do
      offer(index, ~D[2026-09-13], %{
        minimum_commitment_months: 0,
        payment_structure: nil,
        renewal_policy: nil
      })
    end

    assert prices() == expected()
    assert panel_query(4).rows == []
    assert comparison_status() =~ "0 gyms match"
    assert Enum.all?(chart().rows, &(List.last(&1) == "2026-09-13"))
  end

  test "payment selectors contain only known codes and cannot interpolate executable SQL" do
    for {name, values} <- [
          {"payment_structure", ["recurring", "prepaid_term"]},
          {"renewal_policy", ["automatic", "non_automatic"]}
        ] do
      variable = Enum.find(dashboard()["templating"]["list"], &(&1["name"] == name))
      assert Enum.map(variable["options"], & &1["value"]) == values
      refute variable["includeAll"]
      refute variable["multi"]
      refute variable["allowCustomValue"]
      for index <- 0..2, do: offer(index, ~D[2026-09-12], %{minimum_commitment_months: 0})
      assert panel_query(4, %{name => "' OR '1'='1"}).rows == []
      Repo.delete_all(Membership)
    end
  end

  test "equal amounts with included versus excluded VAT are not the same comparison group" do
    offer(0, ~D[2026-09-12], %{
      minimum_commitment_months: 0,
      advertised_price_aed: Decimal.new("200")
    })

    offer(1, ~D[2026-09-12], %{
      minimum_commitment_months: 0,
      advertised_price_aed: Decimal.new("200"),
      price_vat_status: "excluded"
    })

    offer(2, ~D[2026-09-12], %{minimum_commitment_months: 0, price_vat_status: nil})
    assert panel_query(4).rows == []
    assert comparison_status() =~ "1 gym matches"
    assert panel_query(4, %{"price_vat_status" => "excluded"}).rows == []
    assert length(chart().rows) == 3
  end

  test "VAT-excluded selection keeps raw pre-VAT prices rather than guessing a rate" do
    for index <- 0..1,
        do:
          offer(index, ~D[2026-09-12], %{
            minimum_commitment_months: 0,
            price_vat_status: "excluded"
          })

    offer(2, ~D[2026-09-12], %{minimum_commitment_months: 0})
    assert panel_query(4).rows == []

    assert panel_query(4, %{"price_vat_status" => "excluded"}).rows == [
             ["GymNation", 209.0, "2026-09-12"],
             ["PureGym", 199.0, "2026-09-12"]
           ]

    panel = Enum.find(dashboard()["panels"], &(&1["id"] == 4))
    assert panel["title"] =~ "${price_vat_status:text}"
    assert panel["description"] =~ "pre-VAT charges, not payable totals"
  end

  test "conflicting or known-plus-unknown VAT evidence disqualifies the offer" do
    for value <- ["excluded", nil] do
      Repo.delete_all(Membership)
      for index <- 0..2, do: offer(index, ~D[2026-09-12], %{minimum_commitment_months: 0})
      offer(0, ~D[2026-09-12], %{minimum_commitment_months: 0, price_vat_status: value})
      assert Enum.map(panel_query(4).rows, &hd/1) == ["PureGym", "The Warehouse Gym"]
    end
  end

  test "VAT unknown on a newer complete date does not borrow older tax evidence" do
    for index <- 0..2, do: offer(index, ~D[2026-09-12], %{minimum_commitment_months: 0})

    for index <- 0..2,
        do: offer(index, ~D[2026-09-13], %{minimum_commitment_months: 0, price_vat_status: nil})

    assert panel_query(4).rows == []
    assert comparison_status() =~ "0 gyms match"
    assert Enum.all?(chart().rows, &(List.last(&1) == "2026-09-13"))
  end

  test "fee evidence stays separate, zero remains known, and no upfront fees enter monthly bars" do
    offer(0, ~D[2026-09-12], %{
      minimum_commitment_months: 0,
      joining_fee_aed: Decimal.new("199"),
      admin_fee_aed: Decimal.new("30")
    })

    offer(1, ~D[2026-09-12], %{
      minimum_commitment_months: 0,
      joining_fee_aed: Decimal.new("0"),
      admin_fee_aed: Decimal.new("0"),
      price_vat_status: "excluded"
    })

    offer(2, ~D[2026-09-12], %{minimum_commitment_months: 0, price_vat_status: nil})
    [first, second, third] = evidence()
    assert first["Membership price VAT"] == "VAT included"
    assert first["Joining fee AED"] == 199.0
    assert first["Admin fee AED"] == 30.0
    assert second["Membership price VAT"] == "VAT excluded"
    assert second["Joining fee AED"] == 0.0
    assert second["Admin fee AED"] == 0.0
    assert third["Membership price VAT"] == "Unknown"
    assert third["Joining fee AED"] == nil
    assert third["Admin fee AED"] == nil
    assert prices() == expected()
    assert panel_query(4).rows == []

    # Only the membership-price VAT gate changes; no fee total or inference is added.
    Repo.update_all(Membership, set: [price_vat_status: "included"])
    assert Enum.map(panel_query(4).rows, &Enum.at(&1, 1)) == [209.0, 199.0, 363.0]
  end

  test "VAT selectors cannot combine unknowns or interpolate executable SQL" do
    variable = Enum.find(dashboard()["templating"]["list"], &(&1["name"] == "price_vat_status"))
    assert Enum.map(variable["options"], & &1["value"]) == ["included", "excluded"]
    refute variable["includeAll"]
    refute variable["multi"]
    refute variable["allowCustomValue"]
    for index <- 0..2, do: offer(index, ~D[2026-09-12], %{minimum_commitment_months: 0})
    assert panel_query(4, %{"price_vat_status" => "' OR '1'='1"}).rows == []
  end
end
