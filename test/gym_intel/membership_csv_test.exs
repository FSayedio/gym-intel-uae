defmodule GymIntel.MembershipCSVTest do
  use ExUnit.Case, async: true
  alias GymIntel.MembershipCSV

  defp header, do: Enum.join(MembershipCSV.headers(), ",") <> "\n"

  defp row(notes \\ "", payment \\ "", renewal \\ "", vat \\ "", admin \\ "") do
    [
      [
        "TEST ONLY",
        "",
        "Synthetic plan",
        "all_uae_branches",
        "",
        "100",
        "1",
        "",
        "",
        "https://example.com",
        "",
        "2026-09-12",
        notes,
        payment,
        renewal,
        vat,
        admin
      ]
    ]
    |> NimbleCSV.RFC4180.dump_to_iodata()
    |> IO.iodata_to_binary()
    |> String.trim_trailing()
  end

  test "accepts a header-only CSV without inventing records" do
    assert {:ok, []} = MembershipCSV.parse(header())
  end

  test "reads the project's collected offers without persisting them" do
    assert {:ok, records} = MembershipCSV.read("data/memberships.csv")
    assert length(records) >= 3
    assert Enum.all?(records, &(&1.id == nil and &1.__meta__.state == :built))

    assert MapSet.subset?(
             MapSet.new(["GymNation", "The Warehouse Gym", "PureGym"]),
             MapSet.new(records, & &1.brand_name)
           )
  end

  test "parses and validates a synthetic row without persisting it" do
    assert {:ok, [record]} = MembershipCSV.parse(header() <> row())
    assert record.brand_name == "TEST ONLY"
    assert record.id == nil
    assert record.__meta__.state == :built
    assert Decimal.equal?(record.advertised_price_aed, Decimal.new("100"))
    assert record.joining_fee_aed == nil
  end

  test "preserves quoted commas, escaped quotes and embedded newlines" do
    csv = header() <> row("Includes towel, and \"locker\"\nSecond line") <> "\n"
    assert {:ok, [record]} = MembershipCSV.parse(csv)
    assert record.notes == "Includes towel, and \"locker\"\nSecond line"
  end

  test "current headers carry explicit payment and renewal values" do
    assert length(MembershipCSV.headers()) == 17
    assert {:ok, [record]} = MembershipCSV.parse(header() <> row("", "prepaid_term", "automatic"))
    assert record.payment_structure == "prepaid_term"
    assert record.renewal_policy == "automatic"
    assert record.notes == nil
  end

  test "legacy snapshots retain unknown payment and renewal instead of receiving defaults" do
    legacy =
      "brand_name,branch_name,plan_name,access_scope,offer_type,advertised_price_aed,billing_period_months,minimum_commitment_months,joining_fee_aed,source_url,source_published_on,observed_on,notes\n" <>
        "TEST LEGACY,,Synthetic plan,all_uae_branches,,100,1,,,https://example.com,,2026-09-12,TEST ONLY\n"

    assert {:ok, [record]} = MembershipCSV.parse(legacy)
    assert record.notes == "TEST ONLY"
    assert record.payment_structure == nil
    assert record.renewal_policy == nil
    assert record.price_vat_status == nil
    assert record.admin_fee_aed == nil
  end

  test "payment-era snapshots keep VAT and admin unknown without losing payment terms" do
    contents = header() <> row("TEST ONLY", "recurring", "automatic")
    records = NimbleCSV.RFC4180.parse_string(contents, skip_headers: false)

    legacy =
      records
      |> Enum.map(&Enum.take(&1, 15))
      |> NimbleCSV.RFC4180.dump_to_iodata()
      |> IO.iodata_to_binary()

    assert {:ok, [record]} = MembershipCSV.parse(legacy)
    assert record.payment_structure == "recurring"
    assert record.renewal_policy == "automatic"
    assert record.price_vat_status == nil
    assert record.admin_fee_aed == nil
  end

  test "VAT and admin fee parse separately while quoted source notes are retained" do
    assert {:ok, [record]} =
             MembershipCSV.parse(
               header() <>
                 row("Joining 199, admin 30", "recurring", "automatic", "excluded", "30.00")
             )

    assert record.price_vat_status == "excluded"
    assert Decimal.equal?(record.admin_fee_aed, Decimal.new("30"))
    assert record.joining_fee_aed == nil
    assert record.notes == "Joining 199, admin 30"

    assert {:error, {:rows, [%{errors: %{admin_fee_aed: _}}]}} =
             MembershipCSV.parse(header() <> row("", "", "", "included", "-1"))

    assert {:error, {:rows, [%{errors: %{price_vat_status: _}}]}} =
             MembershipCSV.parse(header() <> row("", "", "", "assumed", ""))
  end

  test "rejects partial header extensions and invented classifications" do
    partial_header = MembershipCSV.headers() |> Enum.drop(-1) |> Enum.join(",")
    assert {:error, :header_mismatch} = MembershipCSV.parse(partial_header <> "\n")

    assert {:error, {:rows, [%{errors: %{payment_structure: _}}]}} =
             MembershipCSV.parse(header() <> row("", "guessed", "automatic"))
  end

  test "accepts CRLF line endings" do
    assert {:ok, [_]} =
             MembershipCSV.parse(String.replace(header() <> row() <> "\n", "\n", "\r\n"))
  end

  test "rejects empty files and incorrect or reordered headers" do
    assert {:error, :missing_header} = MembershipCSV.parse("")
    assert {:error, :header_mismatch} = MembershipCSV.parse("wrong\n")
    reversed = MembershipCSV.headers() |> Enum.reverse() |> Enum.join(",")
    assert {:error, :header_mismatch} = MembershipCSV.parse(reversed)
  end

  test "reports short and long rows by record number" do
    for bad <- ["too,few", row() <> ",extra"] do
      assert {:error, {:rows, [%{record: 2, reason: :column_count}]}} =
               MembershipCSV.parse(header() <> bad)
    end
  end

  test "returns errors instead of partial success when a row is invalid" do
    invalid = String.replace(row(), ",100,1,", ",100,,")

    assert {:error, {:rows, [%{record: 3, reason: :validation, errors: errors}]}} =
             MembershipCSV.parse(header() <> row() <> "\n" <> invalid)

    assert errors.billing_period_months == ["can't be blank"]
  end

  test "reports malformed quoting and invalid UTF-8" do
    assert {:error, :malformed_csv} = MembershipCSV.parse(header() <> "\"unclosed")
    assert {:error, :invalid_utf8} = MembershipCSV.parse(<<255>>)
  end

  test "returns a file error for a missing input" do
    assert {:error, {:file, :enoent}} = MembershipCSV.read("data/nonexistent-test-input.csv")
  end
end
