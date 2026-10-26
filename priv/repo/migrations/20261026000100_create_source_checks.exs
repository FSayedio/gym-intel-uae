defmodule GymIntel.Repo.Migrations.CreateSourceChecks do
  use Ecto.Migration

  def up do
    create table(:source_check_states, primary_key: false) do
      add(:source_id, :text, primary_key: true)
      add(:content_hash, :text, null: false)
      add(:content_text, :text, null: false)
      add(:accepted_hash, :text)
      add(:accepted_text, :text)
      add(:checked_at, :utc_datetime_usec, null: false)
    end

    create table(:source_check_reports) do
      add(:checked_at, :utc_datetime_usec, null: false)
      add(:report, :map, null: false)
    end

    execute("""
    DO $$ BEGIN
      REVOKE ALL ON source_check_states, source_check_reports FROM PUBLIC;
      IF EXISTS (SELECT FROM pg_roles WHERE rolname = 'gym_intel_app') THEN
        GRANT SELECT, INSERT, UPDATE ON source_check_states TO gym_intel_app;
        GRANT SELECT, INSERT, DELETE ON source_check_reports TO gym_intel_app;
        GRANT USAGE, SELECT ON SEQUENCE source_check_reports_id_seq TO gym_intel_app;
      END IF;
    END $$;
    """)
  end

  def down do
    drop(table(:source_check_reports))
    drop(table(:source_check_states))
  end
end
