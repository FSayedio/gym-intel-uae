defmodule GymIntel.Repo.Migrations.AddVatAndAdminFees do
  use Ecto.Migration

  def change do
    alter table(:memberships) do
      # Scope VAT to the advertised membership price, not every separate charge.
      # No defaults or backfill: missing historical evidence stays unknown.
      add(:price_vat_status, :string)
      add(:admin_fee_aed, :decimal)
    end

    create(
      constraint(:memberships, :memberships_price_vat_status_allowed,
        check: "price_vat_status IS NULL OR price_vat_status IN ('included', 'excluded')"
      )
    )

    create(
      constraint(:memberships, :memberships_admin_fee_non_negative,
        check: "admin_fee_aed IS NULL OR admin_fee_aed >= 0"
      )
    )
  end
end
