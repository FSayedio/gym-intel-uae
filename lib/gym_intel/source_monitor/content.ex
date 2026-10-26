defmodule GymIntel.SourceMonitor.Content do
  @moduledoc "Page-text comparison, never certification that a selected offer is unchanged."
  @max_text_bytes 100_000

  def extract(html, source) when is_binary(html) do
    with true <- String.valid?(html),
         true <- byte_size(html) <= GymIntel.SourceMonitor.HTTP.max_bytes(),
         {:ok, document} <- Floki.parse_document(html) do
      nodes =
        document
        |> Floki.filter_out("script, style, noscript, svg, nav, footer, header, [hidden]")

      main = Floki.find(nodes, "main")
      nodes = if main == [], do: nodes, else: main

      text = nodes |> Floki.text(sep: " ") |> String.replace(~r/\s+/u, " ") |> String.trim()
      lower = String.downcase(text)

      cond do
        byte_size(text) > @max_text_bytes ->
          {:error, :content_too_large}

        String.length(text) < 40 ->
          {:error, :content_unavailable}

        Enum.any?(
          ["verify you are human", "access denied", "just a moment", "enable javascript"],
          &String.contains?(lower, &1)
        ) ->
          {:error, :blocked_or_dynamic_page}

        not Enum.all?(source.anchors, &String.contains?(lower, &1)) ->
          {:error, :offer_context_missing}

        true ->
          {:ok, %{text: text, hash: hash(text)}}
      end
    else
      _ -> {:error, :invalid_html}
    end
  end

  def classify(nil, _current), do: "baseline"
  def classify(%{hash: previous}, %{hash: current}) when previous == current, do: "page_unchanged"
  def classify(_previous, _current), do: "page_changed"

  defp hash(text), do: :crypto.hash(:sha256, text) |> Base.encode16(case: :lower)
end
