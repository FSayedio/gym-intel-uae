defmodule GymIntel.Repo.Migrations.EnforceObservationIntegrity do
  use Ecto.Migration

  @sql_path Path.expand("../../observation_integrity.sql", __DIR__)
  @external_resource @sql_path

  def up do
    for statement <- String.split(File.read!(@sql_path), "\n-- statement\n", trim: true) do
      execute(statement)
    end
  end

  def down do
    raise Ecto.MigrationError,
          "Automatic rollback would discard note history; use a reviewed forward migration instead"
  end
end
