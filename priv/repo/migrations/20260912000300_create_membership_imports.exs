defmodule GymIntel.Repo.Migrations.CreateMembershipImports do
  use Ecto.Migration

  def change do
    create table(:membership_imports, primary_key: false) do
      add(:content_sha256, :string, primary_key: true)
      add(:row_count, :integer, null: false)
      add(:inserted_at, :utc_datetime_usec, null: false)
    end
  end
end
