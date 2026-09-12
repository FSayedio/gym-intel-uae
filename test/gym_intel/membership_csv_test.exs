defmodule GymIntel.MembershipCSVTest do
  use ExUnit.Case, async: true
  alias GymIntel.MembershipCSV

  defp header, do: Enum.join(MembershipCSV.headers(), ",") <> "\n"

  defp row,
    do: "TEST ONLY,,Synthetic plan,all_uae_branches,,100,1,,,https://example.com,,2026-09-12,"

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
    csv = header() <> row() <> "\"Includes towel, and \"\"locker\"\"\nSecond line\"\n"
    assert {:ok, [record]} = MembershipCSV.parse(csv)
    assert record.notes == "Includes towel, and \"locker\"\nSecond line"
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
