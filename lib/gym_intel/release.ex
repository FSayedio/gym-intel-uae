defmodule GymIntel.Release do
  @moduledoc "Explicit one-off operator tasks for the packaged application, without Mix."

  alias GymIntel.Repo

  def migrate do
    Application.load(:gym_intel)

    {:ok, versions, _apps} =
      Ecto.Migrator.with_repo(Repo, &Ecto.Migrator.run(&1, :up, all: true, log: false))

    IO.puts("Applied migrations: #{length(versions)}")
    :ok
  end

  def enqueue do
    path = System.fetch_env!("IMPORT_CSV_PATH")
    Application.load(:gym_intel)

    # This short-lived process only submits. The long-running app owns workers.
    config = Application.fetch_env!(:gym_intel, Oban)
    Application.put_env(:gym_intel, Oban, Keyword.merge(config, queues: false, plugins: false))
    {:ok, _apps} = Application.ensure_all_started(:gym_intel)

    case GymIntel.Workers.ImportMemberships.enqueue_file(path) do
      {:ok, job} ->
        IO.puts("Queued import job #{job.id}; check job state for completion.")
        :ok

      {:error, _reason} ->
        # Do not dump raw CSV values or job arguments into operator logs.
        IO.puts(:stderr, "Import not queued: check the CSV path and data contract.")
        System.halt(1)
    end
  end
end
