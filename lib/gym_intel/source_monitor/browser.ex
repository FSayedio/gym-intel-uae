defmodule GymIntel.SourceMonitor.Browser do
  @moduledoc "Read one fixed JavaScript-rendered source with a short-lived sandboxed browser."
  alias GymIntel.SourceMonitor.Sources
  @max_output 700_000

  def fetch(url) do
    cond do
      url != Sources.rendered_url() -> {:error, :unapproved_url}
      is_nil(System.find_executable("node")) -> {:error, :browser_unavailable}
      true -> run(url)
    end
  end

  defp run(url) do
    script = Application.app_dir(:gym_intel, "priv/source_monitor/render.mjs")

    port =
      Port.open(
        {:spawn_executable, System.find_executable("node")},
        [:binary, :exit_status, :use_stdio, :hide, args: [script, url]]
      )

    try do
      collect(port, "", System.monotonic_time(:millisecond) + 70_000)
    after
      if Port.info(port), do: Port.close(port)
    end
  end

  defp collect(port, output, deadline) do
    remaining = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {^port, {:data, chunk}} ->
        if byte_size(output) + byte_size(chunk) > @max_output,
          do: {:error, :browser_content_too_large},
          else: collect(port, output <> chunk, deadline)

      {^port, {:exit_status, _status}} ->
        decode(output)
    after
      remaining -> {:error, :browser_timeout}
    end
  end

  @doc false
  def decode(output) do
    case Jason.decode(output) do
      {:ok, %{"ok" => true, "url" => url, "text" => text}} when is_binary(text) ->
        if url == Sources.rendered_url() and String.valid?(text) and byte_size(text) <= 100_000 do
          escaped =
            text
            |> String.replace("&", "&amp;")
            |> String.replace("<", "&lt;")
            |> String.replace(">", "&gt;")

          {:ok, "<main>" <> escaped <> "</main>"}
        else
          {:error, :invalid_rendered_page}
        end

      {:ok, %{"ok" => false, "reason" => reason}} ->
        {:error, {:browser, reason}}

      _ ->
        {:error, :invalid_rendered_page}
    end
  end
end
