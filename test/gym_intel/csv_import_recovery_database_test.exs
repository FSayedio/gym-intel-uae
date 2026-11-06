defmodule GymIntel.CSVImportRecoveryDatabaseTest do
  use ExUnit.Case, async: false
  import Ecto.Query
  alias Ecto.Adapters.SQL.Sandbox
  alias GymIntel.{CSVImportRecovery, Membership, MembershipCSV, MembershipImporter, Repo}
  alias GymIntel.Workers.ImportMemberships
  @moduletag :database
  @moduletag :capture_log

  defmodule TimeoutProbe do
    def timeout(_job), do: 1_000
  end

  setup do
    tag = "csv-recovery-test-#{System.unique_integer([:positive])}"
    brand = "TEST RECOVERY #{tag}"

    on_exit(fn ->
      db(fn ->
        jobs = Repo.all(from(j in Oban.Job, where: ^tag in j.tags), log: false)

        hashes =
          for j <- jobs, do: :crypto.hash(:sha256, j.args["csv"]) |> Base.encode16(case: :lower)

        ids =
          Repo.all(from(m in Membership, where: m.brand_name == ^brand, select: m.id), log: false)

        Repo.delete_all(from(n in "membership_notes", where: n.membership_id in ^ids), log: false)
        Repo.delete_all(from(m in Membership, where: m.id in ^ids), log: false)

        Repo.delete_all(from(i in "membership_imports", where: i.content_sha256 in ^hashes),
          log: false
        )

        Repo.delete_all(from(j in Oban.Job, where: ^tag in j.tags), log: false)
      end)
    end)

    {:ok, tag: tag, brand: brand}
  end

  defp db(fun), do: Sandbox.unboxed_run(Repo, fun)

  defp csv(ctx, number \\ 1) do
    [
      MembershipCSV.headers(),
      [
        ctx.brand,
        "TEST BRANCH",
        "TEST PLAN #{number}",
        "single_branch",
        "standard",
        "199",
        "1",
        "0",
        "0",
        "https://example.com/recovery",
        "",
        "2000-01-01",
        "SYNTHETIC ONLY",
        "recurring",
        "automatic",
        "included",
        "0"
      ]
    ]
    |> NimbleCSV.RFC4180.dump_to_iodata()
    |> IO.iodata_to_binary()
  end

  defp job(ctx, opts \\ []) do
    contents = Keyword.get_lazy(opts, :csv, fn -> csv(ctx) end)
    attrs = Keyword.get(opts, :attrs, [])

    db(fn ->
      ImportMemberships.new(%{"csv" => contents}, tags: [ctx.tag])
      |> Ecto.Changeset.change(
        Keyword.merge([state: "executing", attempt: 1, attempted_at: DateTime.utc_now()], attrs)
      )
      |> Repo.insert!()
    end)
  end

  defp future, do: DateTime.add(DateTime.utc_now(), CSVImportRecovery.rescue_after() + 5, :second)
  defp state(job), do: db(fn -> Repo.get!(Oban.Job, job.id).state end)

  defp count(ctx),
    do:
      db(fn ->
        Repo.aggregate(from(m in Membership, where: m.brand_name == ^ctx.brand), :count)
      end)

  defp start_attempt(job, parent, fun) do
    spawn_monitor(fn ->
      db(fn ->
        CSVImportRecovery.with_attempt(job, fn ->
          result = fun.()
          send(parent, {:owned, self()})

          receive do
            :finish -> result
          end
        end)
      end)
    end)
  end

  defp replacement(job) do
    db(fn ->
      Repo.get!(Oban.Job, job.id)
      |> Ecto.Changeset.change(
        state: "executing",
        attempt: job.attempt + 1,
        attempted_at: DateTime.add(job.attempted_at, 1, :second)
      )
      |> Repo.update!()
    end)
  end

  defp eventually(fun, remaining \\ 100)
  defp eventually(fun, 0), do: assert(fun.())

  defp eventually(fun, remaining) do
    unless fun.() do
      Process.sleep(10)
      eventually(fun, remaining - 1)
    end
  end

  test "recovery skips a live row lock and still recovers an unrelated abandoned job", ctx do
    live = job(ctx)
    orphan = job(ctx, csv: csv(ctx, 2))
    {pid, monitor} = start_attempt(live, self(), fn -> {:ok, :held} end)

    try do
      assert_receive {:owned, ^pid}, 2_000

      assert {:ok, %{rescued: [id], discarded: []}} =
               db(fn -> CSVImportRecovery.sweep(future()) end)

      assert id == orphan.id
      assert state(live) == "executing"
    after
      send(pid, :finish)
    end

    assert_receive {:DOWN, ^monitor, :process, ^pid, :normal}, 2_000
  end

  test "an obsolete attempt cannot enter the importer before or after replacement starts", ctx do
    old = job(ctx)
    assert {:ok, %{rescued: [_]}} = db(fn -> CSVImportRecovery.sweep(future()) end)
    assert {:cancel, :stale_attempt} = db(fn -> ImportMemberships.perform(old) end)
    assert state(old) == "available"
    new = replacement(old)
    assert {:cancel, :stale_attempt} = db(fn -> ImportMemberships.perform(old) end)
    assert count(ctx) == 0
    assert {:ok, {:imported, %{inserted: 1}}} = db(fn -> ImportMemberships.perform(new) end)
  end

  test "killing an owner rolls back facts and receipt before a successful replacement", ctx do
    old = job(ctx)

    {pid, monitor} =
      start_attempt(old, self(), fn -> MembershipImporter.import_csv(old.args["csv"]) end)

    try do
      assert_receive {:owned, ^pid}, 2_000
      assert count(ctx) == 0
      assert {:ok, %{rescued: []}} = db(fn -> CSVImportRecovery.sweep(future()) end)
      Process.exit(pid, :kill)
      assert_receive {:DOWN, ^monitor, :process, ^pid, :killed}, 2_000

      eventually(fn ->
        {:ok, result} = db(fn -> CSVImportRecovery.sweep(future()) end)
        old.id in result.rescued or state(old) == "available"
      end)

      assert count(ctx) == 0
      new = replacement(old)
      assert {:ok, {:imported, %{inserted: 1}}} = db(fn -> ImportMemberships.perform(new) end)
      assert count(ctx) == 1
    after
      if Process.alive?(pid), do: Process.exit(pid, :kill)
    end
  end

  test "committed import survives lost acknowledgement and retry uses its fingerprint", ctx do
    old = job(ctx)
    assert {:ok, {:imported, %{inserted: 1}}} = db(fn -> ImportMemberships.perform(old) end)
    assert state(old) == "executing"
    assert {:ok, %{rescued: [_]}} = db(fn -> CSVImportRecovery.sweep(future()) end)
    new = replacement(old)
    assert {:ok, :already_imported} = db(fn -> ImportMemberships.perform(new) end)
    assert count(ctx) == 1

    db(fn ->
      conf = Oban.Config.new(repo: Repo, testing: :manual)
      :ok = Oban.Engines.Basic.complete_job(conf, old)
      assert Repo.get!(Oban.Job, old.id).state == "executing"
      :ok = Oban.Engines.Basic.complete_job(conf, new)
      assert Repo.get!(Oban.Job, old.id).state == "completed"
    end)
  end

  test "late failure and cancellation cannot overwrite a replacement attempt", ctx do
    old = job(ctx)
    assert {:ok, %{rescued: [_]}} = db(fn -> CSVImportRecovery.sweep(future()) end)
    new = replacement(old)

    db(fn ->
      conf = Oban.Config.new(repo: Repo, testing: :manual)

      late = %{
        old
        | unsaved_error: %{
            kind: :error,
            reason: RuntimeError.exception("synthetic late failure"),
            stacktrace: []
          }
      }

      :ok = Oban.Engines.Basic.error_job(conf, late, 10)
      :ok = Oban.Engines.Basic.cancel_job(conf, late)
      current = Repo.get!(Oban.Job, old.id)
      assert current.state == "executing"
      assert current.attempted_at == new.attempted_at
    end)
  end

  test "exhausted attempts are discarded without extending the retry budget", ctx do
    old = job(ctx, attrs: [attempt: 3])

    assert {:ok, %{rescued: [], discarded: [id]}} =
             db(fn -> CSVImportRecovery.sweep(future()) end)

    assert id == old.id

    db(fn ->
      current = Repo.get!(Oban.Job, id)
      assert current.state == "discarded"
      assert current.max_attempts == 3
      assert current.attempt == 3
      assert [%{"attempt" => 3, "error" => error}] = current.errors
      refute String.contains?(error, old.args["csv"])
    end)
  end

  test "legacy jobs, source checks, fresh jobs and terminal jobs are left alone", ctx do
    legacy = job(ctx, attrs: [meta: %{}])
    source = job(ctx, attrs: [worker: "GymIntel.Workers.CheckSources", queue: "source_checks"])
    fresh = job(ctx)
    terminal = job(ctx, attrs: [state: "cancelled"])
    old_time = DateTime.add(DateTime.utc_now(), -CSVImportRecovery.rescue_after() - 5, :second)

    db(fn ->
      Repo.update_all(from(j in Oban.Job, where: j.id in ^[legacy.id, source.id, terminal.id]),
        set: [attempted_at: old_time]
      )
    end)

    assert {:ok, %{rescued: [], discarded: []}} = db(fn -> CSVImportRecovery.sweep() end)
    assert state(fresh) == "executing"
    assert state(legacy) == "executing"
    assert state(source) == "executing"
    assert state(terminal) == "cancelled"
  end

  test "failure inside the owned transaction rolls back the nested import", ctx do
    old = job(ctx)

    assert {:error, :synthetic_failure} =
             db(fn ->
               CSVImportRecovery.with_attempt(old, fn ->
                 assert {:ok, {:imported, _}} = MembershipImporter.import_csv(old.args["csv"])
                 {:error, :synthetic_failure}
               end)
             end)

    assert count(ctx) == 0
  end

  test "concurrent recovery sweeps claim a released attempt only once", ctx do
    old = job(ctx)
    parent = self()

    tasks =
      for _ <- 1..2 do
        Task.async(fn ->
          send(parent, {:ready, self()})

          receive do
            :go -> db(fn -> CSVImportRecovery.sweep(future()) end)
          end
        end)
      end

    for _ <- tasks, do: assert_receive({:ready, _}, 2_000)
    Enum.each(tasks, &send(&1.pid, :go))

    rescued =
      Enum.flat_map(tasks, fn task ->
        assert {:ok, result} = Task.await(task, 5_000)
        result.rescued
      end)

    assert rescued == [old.id]
    assert state(old) == "available"
    assert length(db(fn -> Repo.get!(Oban.Job, old.id).errors end)) == 1
  end

  test "a server-side deadline releases ownership while the old process is still alive", ctx do
    old = job(ctx)
    parent = self()

    {pid, monitor} =
      spawn_monitor(fn ->
        result =
          try do
            db(fn ->
              CSVImportRecovery.with_attempt(old, fn ->
                Repo.query!("SET LOCAL transaction_timeout = '0'", [], log: false)
                Repo.query!("SET LOCAL transaction_timeout = '500ms'", [], log: false)
                result = MembershipImporter.import_csv(old.args["csv"])
                send(parent, {:owned, self()})

                receive do
                  :finish -> result
                end
              end)
            end)
          rescue
            error -> {:raised, error.__struct__}
          end

        send(parent, {:old_result, result})
      end)

    try do
      assert_receive {:owned, ^pid}, 2_000

      eventually(
        fn ->
          {:ok, result} = db(fn -> CSVImportRecovery.sweep(future()) end)
          old.id in result.rescued or state(old) == "available"
        end,
        200
      )

      assert Process.alive?(pid)
      assert count(ctx) == 0
      new = replacement(old)
      assert {:ok, {:imported, %{inserted: 1}}} = db(fn -> ImportMemberships.perform(new) end)
      send(pid, :finish)
      assert_receive {:old_result, {:raised, _}}, 2_000
      assert_receive {:DOWN, ^monitor, :process, ^pid, :normal}, 2_000
      assert count(ctx) == 1
    after
      if Process.alive?(pid), do: Process.exit(pid, :kill)
    end
  end

  test "Oban's execution timer ends an owned attempt and PostgreSQL rolls it back", ctx do
    old = job(ctx)
    parent = self()

    {pid, monitor} =
      spawn_monitor(fn ->
        # Exercise the installed Oban timer with a shorter test-only callback.
        # The production worker's two-minute callback is asserted separately.
        conf = Oban.Config.new(repo: Repo, testing: :manual)
        executor = %{Oban.Queues.Executor.new(conf, old) | worker: TimeoutProbe}
        Oban.Queues.Executor.start_timeout(executor)

        db(fn ->
          CSVImportRecovery.with_attempt(old, fn ->
            result = MembershipImporter.import_csv(old.args["csv"])
            send(parent, {:owned, self()})

            receive do
              :finish -> result
            end
          end)
        end)
      end)

    try do
      assert_receive {:owned, ^pid}, 2_000
      assert_receive {:DOWN, ^monitor, :process, ^pid, %Oban.TimeoutError{}}, 2_000

      eventually(fn ->
        {:ok, result} = db(fn -> CSVImportRecovery.sweep(future()) end)
        old.id in result.rescued or state(old) == "available"
      end)

      assert count(ctx) == 0
    after
      if Process.alive?(pid), do: Process.exit(pid, :kill)
    end
  end

  test "the recovery process notifies a real Oban queue and the same job completes on attempt two",
       ctx do
    old_time = DateTime.add(DateTime.utc_now(), -CSVImportRecovery.rescue_after() - 5, :second)
    old = job(ctx, attrs: [attempted_at: old_time])
    Sandbox.mode(Repo, :auto)
    on_exit(fn -> Sandbox.mode(Repo, :manual) end)

    name = GymIntel.CSVRecoveryTestOban

    start_supervised!(
      {Oban,
       name: name,
       repo: Repo,
       testing: :disabled,
       queues: [imports: 1],
       plugins: false,
       peer: false}
    )

    plugin =
      start_supervised!(
        {CSVImportRecovery.Plugin, conf: Oban.config(name), name: GymIntel.CSVRecoveryTestPlugin}
      )

    send(plugin, :sweep)

    eventually(fn -> state(old) == "completed" end, 1_000)
    current = db(fn -> Repo.get!(Oban.Job, old.id) end)
    assert current.attempt == 2
    assert current.max_attempts == 3
    assert count(ctx) == 1
    assert current.args == old.args
    stop_supervised!(CSVImportRecovery.Plugin)
    stop_supervised!(name)
  end

  @tag timeout: 180_000
  test "a near-limit valid CSV imports within the proposed execution budget", ctx do
    header = NimbleCSV.RFC4180.dump_to_iodata([MembershipCSV.headers()]) |> IO.iodata_to_binary()

    {rows, _size} =
      Enum.reduce_while(1..20_000, {[], byte_size(header)}, fn i, {rows, size} ->
        [_header, row] = NimbleCSV.RFC4180.parse_string(csv(ctx, i), skip_headers: false)
        encoded = NimbleCSV.RFC4180.dump_to_iodata([row]) |> IO.iodata_to_binary()

        if size + byte_size(encoded) > MembershipCSV.max_bytes(),
          do: {:halt, {rows, size}},
          else: {:cont, {[encoded | rows], size + byte_size(encoded)}}
      end)

    contents = IO.iodata_to_binary([header | Enum.reverse(rows)])
    assert byte_size(contents) >= 990_000
    old = job(ctx, csv: contents)
    {elapsed, result} = :timer.tc(fn -> db(fn -> ImportMemberships.perform(old) end) end)
    assert {:ok, {:imported, %{inserted: inserted}}} = result
    assert inserted == length(rows)
    assert count(ctx) == inserted
    assert elapsed < CSVImportRecovery.execution_limit() * 1_000

    IO.puts(
      "CSV RECOVERY MEASUREMENT: bytes=#{byte_size(contents)} rows=#{inserted} elapsed_ms=#{div(elapsed, 1_000)} limit_ms=#{CSVImportRecovery.execution_limit()}"
    )
  end
end
