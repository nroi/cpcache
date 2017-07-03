defmodule Cpc.Downloader do
  require Logger
  use GenServer
  alias Cpc.Utils
  alias Cpc.Downloader, as: Dload
  defstruct url: nil,
            save_to: nil,
            start_from: nil,
            receiver: nil,
            distro: nil,
            start_time: nil


  # Process for downloading the given URL starting from byte start_from to the filename at path
  # save_to.

  def bandwidth_to_human_readable(bytes, microseconds) do
    bytes_per_second = bytes / (microseconds / 1000000)
    exponent = :erlang.trunc(:math.log2(bytes_per_second) / :math.log2(1024))
    prefix = case exponent do
               1 -> "Ki"
               2 -> "Mi"
               3 -> "Gi"
               4 -> "Ti"
               5 -> "Pi"
               6 -> "Ei"
               7 -> "Zi"
               8 -> "Yi"
               _ -> ""
             end
    quantity = Float.round(bytes_per_second / :math.pow(1024, exponent), 2)
    unit = "#{prefix}B/s"
    "#{quantity} #{unit}"
  end

  # Returns the download stats from the previous duration_seconds seconds.
  def stats_from(duration_seconds) do
    microsecs = :erlang.system_time(:micro_seconds) - duration_seconds * 1000000
    head = {DownloadSpeed, "repo.helios.click", :"$1", :"$2", :"$3"}
    {:atomic, data} = :mnesia.transaction(fn ->
      :mnesia.select(DownloadSpeed, [{head, [{:>, :"$2", microsecs}], [:"$$"]}])
    end)
    data
  end

  def measure_speed(request, content_length) do
    now = :erlang.system_time(:micro_seconds)
    diff = now - request.start_time
    _ = Logger.debug "Download of URL #{request.url} to file #{request.save_to} has completed."
    _ = Logger.debug "Content length is: #{content_length}"
    speed = bandwidth_to_human_readable(content_length, diff)
    secs = Float.round(diff / 1000000, 2)
    _ = Logger.debug "Received #{content_length} bytes in #{secs} seconds (#{speed})."
    host = URI.parse(to_string(request.url)).host
    {:atomic, :ok} = :mnesia.transaction(fn ->
      :mnesia.write({DownloadSpeed, host, content_length, request.start_time, diff})
    end)
  end

  def handle_success(headers, client, request) do
    headers = Utils.headers_to_lower(headers)
    content_length = :proplists.get_value("content-length", headers) |> String.to_integer
    Logger.debug "Content-length: #{content_length}"
    full_content_length = case :proplists.get_value("content-range", headers) do
      :undefined ->
        content_length
      header_line ->
        [_, length] = String.split(header_line, "/")
        String.to_integer(length)
    end
    send request.receiver, {:content_length, full_content_length}
    path = url_without_host(request.url)
    {:atomic, :ok} = :mnesia.transaction(fn ->
      :mnesia.write({ContentLength, {request.distro, Path.basename(path)}, full_content_length})
    end)
    {:ok, file} = File.open(request.save_to, [:append, :raw])
    download(client, file)
    measure_speed(request, content_length)
  end

  def handle_failure(404, client, request) do
    send request.receiver, :not_found
    :ok = :hackney.close(client)
    Logger.warn "Download of URL #{request.url} has failed: 404"
  end
  def handle_failure(status, client, request) do
    :ok = :hackney.close(client)
    Logger.warn "Download of URL #{request.url} has failed: #{status}"
    # TODO what to do with other status codes? the receiver should be informed.
  end

  def start_link(url, save_to, receiver, distro, start_from \\ nil) do
    GenServer.start_link(__MODULE__, {to_charlist(url),
                                      to_charlist(save_to),
                                      receiver,
                                      distro,
                                      start_from})
  end

  def init({url, save_to, receiver, distro, start_from}) do
    send self(), :init
    {:ok, {url, save_to, receiver, distro, start_from}}
  end

  def download(client, file) do
    # TODO check if the delayed_write option has some performance implications.
    case :hackney.stream_body(client) do
      {:ok, result} ->
        IO.binwrite(file, result)
        download(client, file)
      :done ->
        :ok = File.close(file)
    end
  end

  def init_get_request(request) do
    headers = case request.start_from do
                nil -> []
                0 -> []
                rs -> [{"Range", "bytes=#{rs}-"}]
              end
    opts = [follow_redirect: true]
    case :hackney.request(:get, request.url, headers, "", opts) do
      {:ok, 200, headers, client} ->
        handle_success(headers, client, request)
      {:ok, 206, headers, client} ->
        handle_success(headers, client, request)
      {:ok, status, _headers, client} ->
        handle_failure(status, client, request)
    end
  end

  def handle_info(:init, {url, save_to, receiver, distro, start_from}) do
    start_time = :erlang.system_time(:micro_seconds)
    request = %Dload{url: url,
                   save_to: save_to,
                   start_from: start_from,
                   receiver: receiver,
                   distro: distro,
                   start_time: start_time}
    init_get_request(request)
    {:stop, :normal, request}
  end

  defp url_without_host(url) do
    url |> to_string |> URI.path_to_segments |> Enum.drop(-2) |> Enum.reverse |> Path.join
  end

end
