defmodule GymIntel.Repo.Migrations.AddPaymentAndRenewalTerms do
  use Ecto.Migration

  def change do
    alter table(:memberships) do
      # No defaults or backfill: historical sources did not establish these facts.
      add(:payment_structure, :string)
      add(:renewal_policy, :string)
    end

    create(
      constraint(:memberships, :memberships_payment_structure_allowed,
        check: "payment_structure IS NULL OR payment_structure IN ('prepaid_term', 'recurring')"
      )
    )

    create(
      constraint(:memberships, :memberships_renewal_policy_allowed,
        check: "renewal_policy IS NULL OR renewal_policy IN ('automatic', 'non_automatic')"
      )
    )
  end
end
