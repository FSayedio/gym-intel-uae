defmodule GymIntel.Membership do
  use Ecto.Schema
  import Ecto.Changeset

  @fields ~w(brand_name branch_name plan_name access_scope offer_type advertised_price_aed billing_period_months minimum_commitment_months joining_fee_aed source_url source_published_on observed_on notes payment_structure renewal_policy price_vat_status admin_fee_aed)a
  @money_fields ~w(advertised_price_aed joining_fee_aed admin_fee_aed)a
  @month_fields ~w(billing_period_months minimum_commitment_months)a
  # Decimal's default parser allows 34 significant digits. Reserve two for fils
  # rather than relaxing that dependency safeguard for oversized money inputs.
  @max_money_digits 32
  @max_money_coefficient Integer.pow(10, @max_money_digits) - 1
  @max_months 2_147_483_647
  @money_pattern ~r/\A[0-9]{1,32}(?:\.[0-9]{1,2})?\z/
  @months_pattern ~r/\A-?[0-9]{1,10}\z/

  schema "memberships" do
    field(:brand_name, :string)
    field(:branch_name, :string)
    field(:plan_name, :string)
    field(:access_scope, :string)
    field(:offer_type, :string)
    field(:advertised_price_aed, :decimal)
    field(:billing_period_months, :integer)
    field(:minimum_commitment_months, :integer)
    field(:joining_fee_aed, :decimal)
    field(:source_url, :string)
    field(:source_published_on, :date)
    field(:observed_on, :date)
    field(:notes, :string)
    field(:payment_structure, :string)
    field(:renewal_policy, :string)
    field(:price_vat_status, :string)
    field(:admin_fee_aed, :decimal)

    timestamps(type: :utc_datetime_usec)
  end

  def source_fields, do: @fields

  def changeset(membership, attrs, opts \\ []) do
    {safe_attrs, input_errors} = check_raw_attrs(attrs)
    today = Keyword.get_lazy(opts, :today, &observation_today/0)

    membership
    |> cast(safe_attrs, @fields)
    |> add_input_errors(input_errors)
    |> validate_required([:brand_name, :plan_name, :access_scope, :source_url, :observed_on])
    |> validate_inclusion(:access_scope, [
      "single_branch",
      "multiple_named_branches",
      "all_uae_branches"
    ])
    |> validate_inclusion(:offer_type, ["standard", "promotional"])
    |> validate_inclusion(:payment_structure, ["prepaid_term", "recurring"])
    |> validate_inclusion(:renewal_policy, ["automatic", "non_automatic"])
    |> validate_inclusion(:price_vat_status, ["included", "excluded"])
    |> validate_number(:advertised_price_aed, greater_than_or_equal_to: 0)
    |> validate_number(:billing_period_months,
      greater_than: 0,
      less_than_or_equal_to: @max_months
    )
    |> validate_number(:minimum_commitment_months,
      greater_than_or_equal_to: 0,
      less_than_or_equal_to: @max_months
    )
    |> validate_number(:joining_fee_aed, greater_than_or_equal_to: 0)
    |> validate_number(:admin_fee_aed, greater_than_or_equal_to: 0)
    |> validate_source_url()
    |> validate_dates(today)
    |> validate_related_fields()
  end

  @doc "The UAE observation day (UTC+4); an explicit instant supports deterministic clock tests."
  def observation_today(now \\ DateTime.utc_now()) do
    now
    |> DateTime.shift_zone!("Etc/UTC")
    |> DateTime.add(4, :hour)
    |> DateTime.to_date()
  end

  # Reject problematic representations before Ecto/Decimal converts them.
  # Removing an invalid attribute here never makes it valid: its field error
  # is attached immediately after cast. Unknown/zero semantics are unchanged.
  defp check_raw_attrs(attrs) do
    Enum.reduce(@fields, {attrs, []}, fn field, {safe_attrs, errors} ->
      key = if Map.has_key?(attrs, field), do: field, else: Atom.to_string(field)

      case Map.fetch(attrs, key) do
        {:ok, value} ->
          case raw_error(field, value) do
            nil -> {safe_attrs, errors}
            message -> {Map.delete(safe_attrs, key), [{field, message} | errors]}
          end

        :error ->
          {safe_attrs, errors}
      end
    end)
  end

  defp raw_error(field, value) do
    cond do
      is_binary(value) and not String.valid?(value) ->
        "must be valid UTF-8"

      is_binary(value) and String.contains?(value, <<0>>) ->
        "must not contain NUL characters"

      field in @money_fields and not valid_money_input?(value) ->
        "must be an ordinary non-negative AED amount with at most 32 whole digits and 2 decimal places"

      field in @month_fields and not valid_month_input?(value) ->
        "must be a whole number within the database integer range"

      true ->
        nil
    end
  end

  defp valid_money_input?(nil), do: true

  defp valid_money_input?(value) when is_binary(value) do
    byte_size(value) <= @max_money_digits + 3 and
      (String.trim(value) == "" or Regex.match?(@money_pattern, value))
  end

  defp valid_money_input?(value) when is_integer(value) do
    value >= 0 and value <= @max_money_coefficient
  end

  defp valid_money_input?(%Decimal{coef: coef, exp: exp, sign: sign})
       when is_integer(coef) and coef >= 0 and is_integer(exp) and exp >= -2 and
              exp < @max_money_digits and sign in [-1, 1] do
    coef < Integer.pow(10, @max_money_digits - exp)
  end

  defp valid_money_input?(_value), do: false

  defp valid_month_input?(nil), do: true

  defp valid_month_input?(value) when is_binary(value) do
    byte_size(value) <= 11 and (String.trim(value) == "" or Regex.match?(@months_pattern, value))
  end

  defp valid_month_input?(value) when is_integer(value) do
    value >= -2_147_483_648 and value <= @max_months
  end

  defp valid_month_input?(_value), do: false

  defp add_input_errors(changeset, errors) do
    Enum.reduce(errors, changeset, fn {field, message}, changeset ->
      add_error(changeset, field, message, validation: :input)
    end)
  end

  defp validate_source_url(changeset) do
    validate_change(changeset, :source_url, fn field, value ->
      case URI.new(value) do
        {:ok, %URI{userinfo: userinfo}} when not is_nil(userinfo) ->
          [{field, "must not contain embedded credentials"}]

        {:ok, %URI{scheme: scheme, host: host}}
        when scheme in ["http", "https"] and is_binary(host) and host != "" ->
          []

        _ ->
          [{field, "must be an HTTP or HTTPS URL with a host"}]
      end
    end)
  end

  defp validate_dates(changeset, today) do
    observed = get_field(changeset, :observed_on)
    published = get_field(changeset, :source_published_on)

    changeset =
      if match?(%Date{}, observed) and Date.compare(observed, today) == :gt do
        add_error(changeset, :observed_on, "must not be in the future (UAE date)")
      else
        changeset
      end

    if match?(%Date{}, observed) and match?(%Date{}, published) and
         Date.compare(published, observed) == :gt do
      add_error(changeset, :source_published_on, "must not be later than the observation date")
    else
      changeset
    end
  end

  defp validate_related_fields(changeset) do
    changeset =
      if get_field(changeset, :access_scope) == "single_branch" do
        validate_required(changeset, [:branch_name])
      else
        changeset
      end

    changeset =
      if not is_nil(get_field(changeset, :advertised_price_aed)) do
        validate_required(changeset, [:billing_period_months])
      else
        changeset
      end

    if is_nil(get_field(changeset, :advertised_price_aed)) and
         is_nil(get_field(changeset, :minimum_commitment_months)) do
      add_error(changeset, :advertised_price_aed, "provide a price or minimum commitment")
    else
      changeset
    end
  end
end
