defmodule GymIntel.MembershipTest do
  use ExUnit.Case, async: true

  alias GymIntel.Membership
  import Ecto.Changeset, only: [get_field: 2]

  # Synthetic inputs only: these are not sourced gym facts or database records.
  defp valid_attrs do
    %{
      "brand_name" => "TEST ONLY",
      "plan_name" => "Synthetic plan",
      "access_scope" => "all_uae_branches",
      "advertised_price_aed" => "100.50",
      "billing_period_months" => "1",
      "source_url" => "https://example.com/plan",
      "observed_on" => "2026-09-12"
    }
  end

  defp changeset(attrs), do: Membership.changeset(%Membership{}, attrs)

  defp assert_invalid(attrs, field) do
    result = changeset(attrs)
    refute result.valid?
    assert Keyword.has_key?(result.errors, field), inspect(result.errors)
  end

  test "casts CSV strings to decimal, integer and date values" do
    result = changeset(valid_attrs())
    assert result.valid?
    assert Decimal.equal?(get_field(result, :advertised_price_aed), Decimal.new("100.50"))
    assert get_field(result, :billing_period_months) == 1
    assert get_field(result, :observed_on) == ~D[2026-09-12]
  end

  test "required fields reject absent, empty and whitespace values" do
    for field <- ~w(brand_name plan_name access_scope source_url observed_on) do
      assert_invalid(Map.delete(valid_attrs(), field), String.to_existing_atom(field))

      for blank <- ["", "   "] do
        assert_invalid(Map.put(valid_attrs(), field, blank), String.to_existing_atom(field))
      end
    end
  end

  test "single-branch offers require a branch name" do
    attrs = Map.put(valid_attrs(), "access_scope", "single_branch")
    assert_invalid(attrs, :branch_name)
    assert_invalid(Map.put(attrs, "branch_name", "   "), :branch_name)
    assert changeset(Map.put(attrs, "branch_name", "TEST BRANCH")).valid?
  end

  test "accepts only documented scope and offer types" do
    for scope <- ~w(multiple_named_branches all_uae_branches) do
      assert changeset(Map.put(valid_attrs(), "access_scope", scope)).valid?
    end

    for offer <- ["standard", "promotional", ""] do
      assert changeset(Map.put(valid_attrs(), "offer_type", offer)).valid?
    end

    assert_invalid(Map.put(valid_attrs(), "access_scope", "worldwide"), :access_scope)
    assert_invalid(Map.put(valid_attrs(), "offer_type", "guessed"), :offer_type)
  end

  test "monetary fields reject negative and non-numeric values but accept zero" do
    for field <- ~w(advertised_price_aed joining_fee_aed) do
      for bad <- ["-1", "unknown", "AED 100"] do
        assert_invalid(Map.put(valid_attrs(), field, bad), String.to_existing_atom(field))
      end

      assert changeset(Map.put(valid_attrs(), field, "0")).valid?
    end
  end

  test "billing period must be a positive whole number" do
    for bad <- ["0", "-1", "1.5", "unknown", ""] do
      assert_invalid(Map.put(valid_attrs(), "billing_period_months", bad), :billing_period_months)
    end
  end

  test "qualified price strings are rejected rather than stripped into exact prices" do
    for price <- ["from 199", "From AED 199", "199-249", "approximately 199"] do
      assert_invalid(Map.put(valid_attrs(), "advertised_price_aed", price), :advertised_price_aed)
    end
  end

  test "price requires a billing period" do
    assert_invalid(Map.delete(valid_attrs(), "billing_period_months"), :billing_period_months)
  end

  test "commitment must be a non-negative whole number" do
    for bad <- ["-1", "1.5", "unknown"] do
      assert_invalid(
        Map.put(valid_attrs(), "minimum_commitment_months", bad),
        :minimum_commitment_months
      )
    end

    assert changeset(Map.put(valid_attrs(), "minimum_commitment_months", "0")).valid?
  end

  test "unknown price stays nil when a documented zero commitment is present" do
    attrs =
      valid_attrs()
      |> Map.put("advertised_price_aed", "")
      |> Map.put("billing_period_months", "")
      |> Map.put("minimum_commitment_months", "0")
      |> Map.put("joining_fee_aed", "")

    result = changeset(attrs)
    assert result.valid?
    assert get_field(result, :advertised_price_aed) == nil
    assert get_field(result, :joining_fee_aed) == nil
    assert get_field(result, :minimum_commitment_months) == 0
  end

  test "requires a price or commitment" do
    assert_invalid(Map.delete(valid_attrs(), "advertised_price_aed"), :advertised_price_aed)
  end

  test "rejects malformed and impossible dates" do
    for field <- ~w(observed_on source_published_on),
        bad <- ["12/09/2026", "2026-02-30", "unknown"] do
      assert_invalid(Map.put(valid_attrs(), field, bad), String.to_existing_atom(field))
    end
  end

  test "source must have an HTTP or HTTPS scheme and host" do
    for bad <- ["not a URL", "/plan", "https:///", "ftp://example.com/plan"] do
      assert_invalid(Map.put(valid_attrs(), "source_url", bad), :source_url)
    end
  end
end
