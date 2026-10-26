defmodule GymIntel.SourceMonitor.Fetcher do
  @moduledoc false
  alias GymIntel.SourceMonitor.{Browser, HTTP, Sources}

  def fetch(url) do
    if url == Sources.rendered_url(), do: Browser.fetch(url), else: HTTP.fetch(url)
  end
end
