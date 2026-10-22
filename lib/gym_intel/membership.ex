defmodule GymIntel.Membership do
  use Ecto.Schema
  import Ecto.Changeset

  @fields ~w(brand_name branch_name plan_name access_scope offer_type advertised_price_aed billing_period_months minimum_commitment_months joining_fee_aed source_url source_published_on observed_on notes payment_structure renewal_policy price_vat_status admin_fee_aed)a

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

  def changeset(membership, attrs) do
    membership
    |> cast(attrs, @fields)
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
    |> validate_number(:billing_period_months, greater_than: 0)
    |> validate_number(:minimum_commitment_months, greater_than_or_equal_to: 0)
    |> validate_number(:joining_fee_aed, greater_than_or_equal_to: 0)
    |> validate_number(:admin_fee_aed, greater_than_or_equal_to: 0)
    |> validate_source_url()
    |> validate_related_fields()
  end

  defp validate_source_url(changeset) do
    validate_change(changeset, :source_url, fn field, value ->
      case URI.new(value) do
        {:ok, %URI{scheme: scheme, host: host}}
        when scheme in ["http", "https"] and is_binary(host) and host != "" ->
          []

        _ ->
          [{field, "must be an HTTP or HTTPS URL with a host"}]
      end
    end)
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
