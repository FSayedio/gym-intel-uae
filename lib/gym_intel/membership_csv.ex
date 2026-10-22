defmodule GymIntel.MembershipCSV do
  @moduledoc "Reads small UTF-8 membership CSV files without writing to the database."

  alias GymIntel.Membership
  alias NimbleCSV.RFC4180, as: CSV

  @legacy_headers ~w(brand_name branch_name plan_name access_scope offer_type advertised_price_aed billing_period_months minimum_commitment_months joining_fee_aed source_url source_published_on observed_on notes)
  @payment_headers @legacy_headers ++ ~w(payment_structure renewal_policy)
  @headers @payment_headers ++ ~w(price_vat_status admin_fee_aed)

  def headers, do: @headers

  def read(path) do
    case File.read(path) do
      {:ok, contents} -> parse(contents)
      {:error, reason} -> {:error, {:file, reason}}
    end
  end

  def parse(contents) do
    if String.valid?(contents) do
      parse_utf8(contents)
    else
      {:error, :invalid_utf8}
    end
  end

  defp parse_utf8(contents) do
    case CSV.parse_string(contents, skip_headers: false) do
      [] ->
        {:error, :missing_header}

      [headers | rows] when headers in [@headers, @payment_headers, @legacy_headers] ->
        validate_rows(rows, headers)

      [_header | _rows] ->
        {:error, :header_mismatch}
    end
  rescue
    NimbleCSV.ParseError -> {:error, :malformed_csv}
  end

  defp validate_rows(rows, headers) do
    # Record 1 is the header. A quoted multiline value is still one record.
    results = Enum.with_index(rows, 2) |> Enum.map(&validate_row(&1, headers))
    errors = for {:error, error} <- results, do: error

    if errors == [] do
      {:ok, for({:ok, membership} <- results, do: membership)}
    else
      {:error, {:rows, errors}}
    end
  end

  defp validate_row({cells, record}, headers) when length(cells) != length(headers) do
    {:error,
     %{record: record, reason: :column_count, expected: length(headers), actual: length(cells)}}
  end

  defp validate_row({cells, record}, headers) do
    attrs = Map.new(Enum.zip(headers, cells))
    changeset = Membership.changeset(%Membership{}, attrs)

    case Ecto.Changeset.apply_action(changeset, :insert) do
      {:ok, membership} ->
        {:ok, membership}

      {:error, invalid} ->
        errors =
          Ecto.Changeset.traverse_errors(invalid, fn {message, opts} ->
            Enum.reduce(opts, message, fn {key, value}, text ->
              String.replace(text, "%{#{key}}", to_string(value))
            end)
          end)

        {:error, %{record: record, reason: :validation, errors: errors}}
    end
  end
end
