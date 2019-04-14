defmodule Cpc.Downloader do
  require Logger
  use GenServer
  alias Cpc.Utils
  alias Cpc.Downloader, as: Dload
  alias Cpc.TableAccess

  defstruct url: nil,
            save_to: nil,
            start_from: nil,
            receiver: nil,
            start_time: nil

  # Process for downloading the given URL starting from byte start_from to the filename at path
  # save_to.

  def try_all([url | fallbacks], save_to, start_from \\ nil) do
    {:ok, pid} = start_link(url, save_to, self(), start_from)

    receive do
      {:content_length, cl} ->
        {:ok, %{content_length: cl, downloader_pid: pid}}

      err = {:error, _reason} ->
        case fallbacks do
          [] ->
            err

          _ ->
            try_all(fallbacks, save_to, start_from)
        end
    end
  end

  def start_link(url, save_to, receiver, start_from \\ nil) do
    GenServer.start_link(
      __MODULE__,
      {to_charlist(url), to_charlist(save_to), receiver, start_from}
    )
  end

  def init({url, save_to, receiver, start_from}) do
    send(self(), :init)
    {:ok, {url, save_to, receiver, start_from}}
  end

  def bandwidth_to_human_readable(_bytes, microseconds) when microseconds <= 0 do
    raise "duration must be positive to provide meaningful values"
  end

  def bandwidth_to_human_readable(0, _microseconds) do
    "0 B/s"
  end

  def bandwidth_to_human_readable(bytes, microseconds) do
    bytes_per_second = bytes / (microseconds / 1_000_000)
    exponent = :erlang.trunc(:math.log2(bytes_per_second) / :math.log2(1024))

    prefix =
      case exponent do
        0 -> {:ok, ""}
        1 -> {:ok, "Ki"}
        2 -> {:ok, "Mi"}
        3 -> {:ok, "Gi"}
        4 -> {:ok, "Ti"}
        5 -> {:ok, "Pi"}
        6 -> {:ok, "Ei"}
        7 -> {:ok, "Zi"}
        8 -> {:ok, "Yi"}
        _ -> {:error, :too_large}
      end

    case prefix do
      {:ok, prefix} ->
        quantity = Float.round(bytes_per_second / :math.pow(1024, exponent), 2)
        unit = "#{prefix}B/s"
        "#{quantity} #{unit}"

      {:error, :too_large} ->
        "#{bytes_per_second} B/s"
    end
  end

  def measure_speed(request, content_length) do
    now = :erlang.system_time(:micro_seconds)
    diff = now - request.start_time
    _ = Logger.debug("Download of URL #{request.url} to file #{request.save_to} has completed.")
    _ = Logger.debug("Content length is: #{content_length}")
    speed = bandwidth_to_human_readable(content_length, diff)
    secs = Float.round(diff / 1_000_000, 2)
    _ = Logger.debug("Received #{content_length} bytes in #{secs} seconds (#{speed}).")

    :ok
  end

  def handle_redirect(_headers, _request, 21) do
    raise "20 redirections exceeded."
  end

  def handle_redirect(headers, request, num_redirect) do
    headers = Utils.headers_to_lower(headers)
    location = :proplists.get_value("location", headers)
    _ = Logger.debug("Redirected to: #{location}")
    # TODO detect redirect cycle.
    init_get_request(%{request | url: location}, num_redirect)
  end

  def handle_success(headers, client, request) do
    headers = Utils.headers_to_lower(headers)
    content_length = :proplists.get_value("content-length", headers) |> String.to_integer()
    Logger.debug("Content-length: #{content_length}")

    full_content_length =
      case :proplists.get_value("content-range", headers) do
        :undefined ->
          content_length

        header_line ->
          [_, length] = String.split(header_line, "/")
          String.to_integer(length)
      end

    send(request.receiver, {:content_length, full_content_length})
    path = url_without_host(request.url)

    TableAccess.add("content_length", Path.basename(path), full_content_length)

    {:ok, file} = File.open(request.save_to, [:append, :raw])

    with :ok <- download(client, file) do
      measure_speed(request, content_length)
    end
  end

  def handle_failure(reason, client, request) do
    :ok = :hackney.close(client)
    handle_failure(reason, request)
  end

  def handle_failure(reason, request) do
    send(request.receiver, {:error, reason})
    :ok = Logger.warn("Download of URL #{request.url} has failed: #{reason}")
  end

  def download(client, file) do
    case :hackney.stream_body(client) do
      {:ok, result} ->
        IO.binwrite(file, result)
        download(client, file)

      :done ->
        :ok = File.close(file)
        # Apparently, hackney closes the socket automatically when :done is sent. Explicitly closing the client
        # at this point would result in an error.

      m = {:error, _reason} ->
        m
    end
  end

  def init_get_request(request, num_redirect \\ 0) do
    headers =
      case request.start_from do
        nil -> []
        0 -> []
        rs -> [{"Range", "bytes=#{rs}-"}]
      end

    _ =
      Logger.debug(
        "GET #{inspect(request.url)} with headers #{inspect(headers)}"
      )

    # TODO use eyepatch.
    case :hackney.request(:get, request.url, headers, "", []) do
      {:ok, status, headers, client} ->
        case status do
          200 ->
            handle_success(headers, client, request)

          206 ->
            handle_success(headers, client, request)

          301 ->
            handle_redirect(headers, request, num_redirect + 1)

          302 ->
            handle_redirect(headers, request, num_redirect + 1)

          303 ->
            handle_redirect(headers, request, num_redirect + 1)

          307 ->
            handle_redirect(headers, request, num_redirect + 1)

          308 ->
            handle_redirect(headers, request, num_redirect + 1)

          status ->
            handle_failure(status, client, request)
        end

      {:error, reason} ->
        handle_failure(reason, request)
    end
  end

  def handle_info(:init, {url, save_to, receiver, start_from}) do
    start_time = :erlang.system_time(:micro_seconds)

    request = %Dload{
      url: url,
      save_to: save_to,
      start_from: start_from,
      receiver: receiver,
      start_time: start_time
    }

    init_get_request(request)
    {:stop, :normal, request}
  end

  defp url_without_host(url) do
    url |> to_string |> path_to_segments |> Enum.drop(-2) |> Enum.reverse() |> Path.join()
  end

  defp path_to_segments(path) do
    [head | tail] = String.split(path, "/")
    reverse_and_discard_empty(tail, [head])
  end

  defp reverse_and_discard_empty([], acc), do: acc
  defp reverse_and_discard_empty([head], acc), do: [head | acc]
  defp reverse_and_discard_empty(["" | tail], acc), do: reverse_and_discard_empty(tail, acc)

  defp reverse_and_discard_empty([head | tail], acc) do
    reverse_and_discard_empty(tail, [head | acc])
  end
end
