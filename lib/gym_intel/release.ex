defmodule GymIntel.Release do
  @moduledoc "Explicit one-off operator tasks for the packaged application, without Mix."

  alias GymIntel.{MembershipCSV, Repo}

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

    Application.put_env(
      :gym_intel,
      Oban,
      Keyword.merge(config, queues: false, plugins: false, peer: false)
    )

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

  @doc "Submit one bounded snapshot and wait for this exact job and its committed marker."
  def update do
    path = System.fetch_env!("IMPORT_CSV_PATH")

    with {:ok, contents} <- MembershipCSV.read_contents(path),
         {:ok, [_ | _] = rows} <- MembershipCSV.parse(contents) do
      Application.load(:gym_intel)
      config = Application.fetch_env!(:gym_intel, Oban)

      Application.put_env(
        :gym_intel,
        Oban,
        Keyword.merge(config, queues: false, plugins: false, peer: false)
      )

      {:ok, _apps} = Application.ensure_all_started(:gym_intel)
      fingerprint = :crypto.hash(:sha256, contents) |> Base.encode16(case: :lower)

      case %{"csv" => contents}
           |> GymIntel.Workers.ImportMemberships.new(tags: ["dashboard-update"])
           |> Oban.insert() do
        {:ok, job} -> wait_for_update(job.id, fingerprint, length(rows), 300)
        {:error, _} -> update_failure("Import could not be queued")
      end
    else
      _ -> update_failure("Update requires a valid, nonempty CSV; nothing queued")
    end
  end

  defp wait_for_update(_id, _fingerprint, _rows, 0) do
    update_failure("Import wait timed out; job may still finish. No cleanup permitted")
  end

  defp wait_for_update(id, fingerprint, row_count, remaining) do
    case Repo.get(Oban.Job, id) do
      %Oban.Job{state: "completed"} ->
        case Repo.query!(
               "SELECT row_count FROM public.membership_imports WHERE content_sha256 = $1",
               [fingerprint]
             ).rows do
          [[^row_count]] -> IO.puts("UPDATE_VERIFIED #{id} #{fingerprint}")
          _ -> update_failure("Job completed without matching committed import evidence")
        end

      %Oban.Job{state: state} when state in ["cancelled", "discarded"] ->
        update_failure("Import job #{id} is #{state}; no backup or cleanup performed")

      %Oban.Job{} ->
        Process.sleep(1_000)
        wait_for_update(id, fingerprint, row_count, remaining - 1)

      nil ->
        update_failure("Import job disappeared; no cleanup permitted")
    end
  end

  defp update_failure(message) do
    IO.puts(:stderr, message)
    System.halt(1)
  end
end
