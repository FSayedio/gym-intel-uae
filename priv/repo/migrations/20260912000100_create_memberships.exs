defmodule GymIntel.Repo.Migrations.CreateMemberships do
  use Ecto.Migration

  def change do
    create table(:memberships) do
      add(:brand_name, :string, null: false)
      add(:branch_name, :string)
      add(:plan_name, :string, null: false)
      add(:access_scope, :string, null: false)
      add(:offer_type, :string)
      add(:advertised_price_aed, :decimal)
      add(:billing_period_months, :integer)
      add(:minimum_commitment_months, :integer)
      add(:joining_fee_aed, :decimal)
      add(:source_url, :text, null: false)
      add(:source_published_on, :date)
      add(:observed_on, :date, null: false)
      add(:notes, :text)

      timestamps(type: :utc_datetime_usec)
    end

    create(
      constraint(:memberships, :memberships_access_scope_allowed,
        check: "access_scope IN ('single_branch', 'multiple_named_branches', 'all_uae_branches')"
      )
    )

    create(
      constraint(:memberships, :memberships_offer_type_allowed,
        check: "offer_type IS NULL OR offer_type IN ('standard', 'promotional')"
      )
    )

    create(
      constraint(:memberships, :memberships_single_branch_named,
        check: "access_scope <> 'single_branch' OR NULLIF(BTRIM(branch_name), '') IS NOT NULL"
      )
    )

    create(
      constraint(:memberships, :memberships_price_non_negative,
        check: "advertised_price_aed IS NULL OR advertised_price_aed >= 0"
      )
    )

    create(
      constraint(:memberships, :memberships_billing_period_positive,
        check: "billing_period_months IS NULL OR billing_period_months > 0"
      )
    )

    create(
      constraint(:memberships, :memberships_commitment_non_negative,
        check: "minimum_commitment_months IS NULL OR minimum_commitment_months >= 0"
      )
    )

    create(
      constraint(:memberships, :memberships_joining_fee_non_negative,
        check: "joining_fee_aed IS NULL OR joining_fee_aed >= 0"
      )
    )

    create(
      constraint(:memberships, :memberships_price_has_billing_period,
        check: "advertised_price_aed IS NULL OR billing_period_months IS NOT NULL"
      )
    )

    create(
      constraint(:memberships, :memberships_has_price_or_commitment,
        check: "advertised_price_aed IS NOT NULL OR minimum_commitment_months IS NOT NULL"
      )
    )
  end
end
