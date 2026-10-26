defmodule GymIntel.SourceMonitorTest do
  use ExUnit.Case, async: true
  alias GymIntel.SourceMonitor.{Content, HTTP, Sources}

  @source %{anchors: ["test gym", "monthly"]}

  test "visible page text ignores script, navigation and cosmetic whitespace" do
    a =
      "<nav>random 1</nav><main><h1>Test gym</h1><p>Monthly membership price AED 199 for gym access.</p></main><script>random 1</script>"

    b =
      "<nav>random 2</nav><main><h1>Test gym</h1>\n<p>Monthly   membership price AED 199 for gym access.</p></main><script>random 2</script>"

    assert {:ok, first} = Content.extract(a, @source)
    assert {:ok, same} = Content.extract(b, @source)
    assert first.hash == same.hash
    assert Content.classify(nil, first) == "baseline"
    assert Content.classify(first, same) == "page_unchanged"
    assert {:ok, changed} = Content.extract(String.replace(b, "199", "219"), @source)
    assert Content.classify(first, changed) == "page_changed"
  end

  test "missing selector context, challenge pages and invalid or oversized text fail closed" do
    assert {:error, :offer_context_missing} =
             Content.extract(
               "<main>Welcome to this website. Please select a club to continue.</main>",
               @source
             )

    assert {:error, :blocked_or_dynamic_page} =
             Content.extract(
               "Test gym monthly membership: please verify you are human before continuing",
               @source
             )

    assert {:error, :invalid_html} = Content.extract(<<255>>, @source)

    assert {:error, :invalid_html} =
             Content.extract(String.duplicate("x", HTTP.max_bytes() + 1), @source)

    assert {:error, :content_too_large} =
             Content.extract("Test gym monthly " <> String.duplicate("x", 100_001), @source)
  end

  test "HTTP reader refuses arbitrary destinations, redirects and bodies above its cap" do
    assert {:error, :unapproved_url} = HTTP.fetch("http://127.0.0.1:5432")
    state = %{status: nil, headers: [], chunks: [], bytes: 0, error: nil}
    assert {:halt, %{error: {:http_status, 302}}} = HTTP.consume({:status, 302}, state)
    assert {:halt, %{error: {:http_status, 403}}} = HTTP.consume({:status, 403}, state)
    assert {:cont, state} = HTTP.consume({:status, 200}, state)
    assert {:cont, state} = HTTP.consume({:data, "123"}, state)
    assert state.bytes == 3

    assert {:halt, %{error: :response_too_large, chunks: []}} =
             HTTP.consume({:data, String.duplicate("x", HTTP.max_bytes())}, state)
  end

  test "catalog stays on four brands and seven explicitly approved HTTPS routes" do
    assert length(Sources.all()) == 7
    assert length(Enum.uniq(Enum.map(Sources.all(), & &1.gym))) == 4
    assert length(Enum.uniq(Sources.urls())) == 7
    assert Enum.all?(Sources.all(), &(URI.parse(&1.url).scheme == "https" and &1.anchors != []))
  end

  test "unavailable HTTP pool produces a failure result without killing the caller" do
    assert Process.whereis(GymIntel.SourceHTTP) == nil
    assert {:error, :connection_or_timeout} = HTTP.fetch(hd(Sources.urls()))
  end

  test "tests cannot start scheduled checks, and the worker has bounded retries and duration" do
    config = Application.fetch_env!(:gym_intel, Oban)
    assert config[:plugins] == false
    assert config[:queues] == false
    job = GymIntel.Workers.CheckSources.new(%{}) |> Ecto.Changeset.apply_changes()
    assert job.queue == "source_checks"
    assert job.max_attempts == 3
    assert GymIntel.Workers.CheckSources.timeout(job) == 240_000
  end

  test "production cron matches Monday 09:00 Dubai and no adjacent slot" do
    config = Config.Reader.read!("config/config.exs", env: :prod)
    [{Oban.Cron, options}] = config[:gym_intel][Oban][:plugins]
    assert :ok = Oban.Cron.validate(options)
    [{expression, GymIntel.Workers.CheckSources}] = options[:crontab]
    assert options[:timezone] == "Etc/UTC"
    cron = Oban.Cron.Expression.parse!(expression)
    assert Oban.Cron.Expression.now?(cron, ~U[2026-10-26 05:00:00Z])
    refute Oban.Cron.Expression.now?(cron, ~U[2026-10-26 05:01:00Z])
    refute Oban.Cron.Expression.now?(cron, ~U[2026-10-27 05:00:00Z])
  end
end
