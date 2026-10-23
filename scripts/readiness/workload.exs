defmodule GymIntel.Readiness.Workload do
  @moduledoc false
  alias GymIntel.{MembershipCSV, Repo}

  def csv(range) do
    rows =
      Enum.map(range, fn i ->
        [
          "TEST ONLY WORKLOAD #{div(i - 1, 40) + 1}",
          "TEST BRANCH #{rem(i - 1, 40) + 1}",
          "TEST MONTHLY",
          "single_branch",
          "standard",
          to_string(199 + rem(i, 10)),
          "1",
          "0",
          "0",
          "https://example.com/workload/#{i}",
          "",
          "2000-01-01",
          "SYNTHETIC TEST ONLY",
          "recurring",
          "automatic",
          "included",
          "0"
        ]
      end)

    [MembershipCSV.headers() | rows]
    |> NimbleCSV.RFC4180.dump_to_iodata()
    |> IO.iodata_to_binary()
  end

  def interrupted_csv do
    Enum.join(MembershipCSV.headers(), ",") <>
      "\nTEST ONLY INTERRUPTED,TEST BRANCH,TEST MONTHLY,single_branch,standard,199,1,0,0,https://example.com/interrupted,,2000-01-01,SYNTHETIC TEST ONLY,recurring,automatic,included,0\n"
  end

  def write_inputs do
    directory = System.get_env("READINESS_DATA_DIR", "")

    unless directory == "/fixture-data",
      do: raise("Only the generated fixture mount is permitted")

    for {name, contents, expected} <- [
          {"workload.csv", csv(1..1000), 1000},
          {"overlap.csv", csv(501..1500), 1000},
          {"interrupted.csv", interrupted_csv(), 1}
        ] do
      {:ok, rows} = MembershipCSV.parse(contents)
      unless length(rows) == expected, do: raise("Synthetic CSV row count differs")

      if byte_size(contents) > MembershipCSV.max_bytes(),
        do: raise("Synthetic CSV exceeds byte limit")

      path = Path.join(directory, name)
      File.write!(path, contents, [:exclusive])
      File.chmod!(path, 0o644)
      IO.puts("Fixture #{name}: #{expected} rows, #{byte_size(contents)} bytes")
    end
  end

  def run(action) do
    unless System.get_env("READINESS_FIXTURE") == "true" and
             Regex.match?(
               ~r/^gym_intel_release_test_[0-9]+_[0-9]+$/,
               System.get_env("DATABASE_NAME", "")
             ) do
      raise "Readiness tasks require the generated test database"
    end

    suffix =
      String.replace_prefix(System.fetch_env!("DATABASE_NAME"), "gym_intel_release_test_", "")

    prefix = if action == :plans, do: "release_reader_", else: "release_app_"

    unless System.get_env("DATABASE_USER") == prefix <> suffix,
      do: raise("Unexpected verification role")

    Application.load(:gym_intel)

    case action do
      :recover ->
        config = Application.fetch_env!(:gym_intel, Oban)

        Application.put_env(
          :gym_intel,
          Oban,
          Keyword.merge(config, queues: false, plugins: false, peer: false)
        )

        {:ok, _} = Application.ensure_all_started(:gym_intel)

        unless Oban.check_all_queues() == [],
          do: raise("One-off verification must not run workers")

        recover_job()

      :plans ->
        {:ok, _} = Application.ensure_all_started(:ecto_sql)
        {:ok, _} = Application.ensure_all_started(:postgrex)
        {:ok, _} = Repo.start_link()
        Application.load(:oban)
        measure_plans()
    end
  end

  defp recover_job do
    id = System.fetch_env!("READINESS_JOB_ID") |> String.to_integer()
    job = Repo.get!(Oban.Job, id, log: false)

    unless id > 0 and job.state == "executing" and job.attempt == 1 and
             job.worker == "GymIntel.Workers.ImportMemberships" and job.queue == "imports" and
             job.args == %{"csv" => interrupted_csv()} do
      raise "Unexpected fixture job; no recovery performed"
    end

    :ok = Oban.cancel_job(id)

    unless Repo.get!(Oban.Job, id, log: false).state == "cancelled",
      do: raise("Exact job was not cancelled")

    :ok = Oban.retry_job(id)
    job = Repo.get!(Oban.Job, id, log: false)

    unless job.state == "available" and job.attempt == 1,
      do: raise("Exact job was not made available")

    IO.puts(
      "Fixture job #{id}: executing -> cancelled -> available; next attempt is a deliberate retry"
    )
  end

  defp measure_plans do
    dashboard = "/fixture-dashboard.json" |> File.read!() |> Jason.decode!()

    IO.puts(
      "Environment: Elixir #{System.version()}, OTP #{:erlang.system_info(:otp_release)}, Oban #{Application.spec(:oban, :vsn)}"
    )

    for panel <- dashboard["panels"], panel["id"] in [2, 3] do
      target = Enum.find(panel["targets"], &(&1["refId"] == "A"))
      sql = "EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON) " <> target["rawSql"]
      %{rows: [[[plan]]]} = Repo.query!(sql, [], timeout: 30_000, log: false)
      root = plan["Plan"]

      unless root["Actual Rows"] == 1502,
        do: raise("Measured dashboard selected an unexpected offer count")

      IO.puts(
        "MEASUREMENT " <>
          Jason.encode!(%{
            panel: panel["id"],
            offers: root["Actual Rows"],
            planning_ms: plan["Planning Time"],
            execution_ms: plan["Execution Time"],
            shared_hit_blocks: root["Shared Hit Blocks"],
            shared_read_blocks: root["Shared Read Blocks"],
            temp_read_blocks: root["Temp Read Blocks"],
            temp_written_blocks: root["Temp Written Blocks"],
            nodes: plan_nodes(root)
          })
      )
    end
  end

  def plan_nodes(node) do
    [
      Map.take(node, [
        "Node Type",
        "Relation Name",
        "Index Name",
        "Actual Rows",
        "Sort Method",
        "Sort Space Used",
        "Sort Space Type"
      ])
      | Enum.flat_map(Map.get(node, "Plans", []), &plan_nodes/1)
    ]
  end
end
