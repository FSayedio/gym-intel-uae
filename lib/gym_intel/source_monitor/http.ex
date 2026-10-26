defmodule GymIntel.SourceMonitor.HTTP do
  @moduledoc "Bounded HTTPS reads of a fixed allowlist. No credentials, redirects or arbitrary URLs."
  alias GymIntel.SourceMonitor.Sources
  @max_bytes 2_000_000

  def max_bytes, do: @max_bytes

  def fetch(url) do
    if url in Sources.urls() do
      task = Task.async(fn -> request(url) end)

      case Task.yield(task, 25_000) || Task.shutdown(task, :brutal_kill) do
        {:ok, result} -> result
        nil -> {:error, :connection_or_timeout}
      end
    else
      {:error, :unapproved_url}
    end
  end

  defp request(url) do
    request =
      Finch.build(:get, url, [
        {"accept", "text/html"},
        {"accept-encoding", "identity"},
        {"user-agent", "GymIntelSourceCheck/1.0 (weekly public-source change check)"}
      ])

    initial = %{status: nil, headers: [], chunks: [], bytes: 0, error: nil}

    case Finch.stream_while(request, GymIntel.SourceHTTP, initial, &consume/2,
           receive_timeout: 15_000,
           request_timeout: 20_000,
           pool_timeout: 5_000
         ) do
      {:ok, %{error: nil, status: 200} = response} ->
        content_type = response.headers |> List.keyfind("content-type", 0, {"", ""}) |> elem(1)

        if String.starts_with?(String.downcase(content_type), "text/html") do
          {:ok, response.chunks |> Enum.reverse() |> IO.iodata_to_binary()}
        else
          {:error, :unexpected_content_type}
        end

      {:ok, %{error: reason}} when not is_nil(reason) ->
        {:error, reason}

      {:ok, %{status: status}} ->
        {:error, {:http_status, status}}

      {:error, _reason} ->
        {:error, :connection_or_timeout}
    end
  rescue
    _error in [RuntimeError, ArgumentError] -> {:error, :connection_or_timeout}
  catch
    :exit, _reason -> {:error, :connection_or_timeout}
  end

  @doc false
  def consume({:status, status}, state) do
    # Redirects can change geographic scope or leave the reviewed official host.
    if status == 200,
      do: {:cont, %{state | status: status}},
      else: {:halt, %{state | status: status, error: {:http_status, status}}}
  end

  def consume({:headers, headers}, state), do: {:cont, %{state | headers: headers}}

  def consume({:data, chunk}, state) do
    bytes = state.bytes + byte_size(chunk)

    if bytes > @max_bytes do
      {:halt, %{state | error: :response_too_large, chunks: []}}
    else
      {:cont, %{state | bytes: bytes, chunks: [chunk | state.chunks]}}
    end
  end

  def consume(_event, state), do: {:cont, state}
end
