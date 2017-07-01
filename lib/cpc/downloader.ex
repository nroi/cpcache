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
            content_length: nil,
            start_time: nil,
            status: :unknown



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

  def measure_speed(state) do
    now = :erlang.system_time(:micro_seconds)
    diff = now - state.start_time
    _ = Logger.debug "Download of URL #{state.url} to file #{state.save_to} has completed."
    _ = Logger.debug "Content length is: #{state.content_length}"
    speed = bandwidth_to_human_readable(state.content_length, diff)
    secs = Float.round(diff / 1000000, 2)
    _ = Logger.debug "Received #{state.content_length} bytes in #{secs} seconds (#{speed})."
    host = URI.parse(to_string(state.url)).host
    {:atomic, :ok} = :mnesia.transaction(fn ->
      :mnesia.write({DownloadSpeed, host, state.content_length, state.start_time, diff})
    end)
  end

  def handle_success(headers, client, state) do
    headers = Utils.headers_to_lower(headers)
    content_length = :proplists.get_value("content-length", headers) |> String.to_integer
    new_state = %{state | content_length: content_length}
    Logger.debug "Content-length: #{content_length}"
    full_content_length = case :proplists.get_value("content-range", headers) do
      :undefined ->
        content_length
      header_line ->
        [_, length] = String.split(header_line, "/")
        String.to_integer(length)
    end
    send state.receiver, {:content_length, full_content_length}
    path = url_without_host(state.url)
    {:atomic, :ok} = :mnesia.transaction(fn ->
      :mnesia.write({ContentLength, {state.distro, Path.basename(path)}, full_content_length})
    end)
    {:ok, file} = File.open(new_state.save_to, [:append, :raw])
    download(client, file)
    measure_speed(new_state)
    new_state
  end

  def handle_failure(404, client, state) do
    # TODO reconsider if we still need the entire 'state' data structure.
    send state.receiver, :not_found
    :ok = :hackney.close(client)
    Logger.warn "Download of URL #{state.url} has failed: 404"
  end
  def handle_failure(status, client, state) do
    :ok = :hackney.close(client)
    Logger.warn "Download of URL #{state.url} has failed: #{status}"
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
    Process.flag(:trap_exit, true)
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

  def init_get_request(state) do
    headers = case state.start_from do
                nil -> []
                0 -> []
                rs -> [{"Range", "bytes=#{rs}-"}]
              end
    opts = [follow_redirect: true]
    case :hackney.request(:get, state.url, headers, "", opts) do
      {:ok, 200, headers, client} ->
        handle_success(headers, client, state)
      {:ok, 206, headers, client} ->
        handle_success(headers, client, state)
      {:ok, status, _headers, client} ->
        handle_failure(status, client, state)
    end
  end

  def handle_info(:init, {url, save_to, receiver, distro, start_from}) do
    start_time = :erlang.system_time(:micro_seconds)
    state = %Dload{url: url,
                   save_to: save_to,
                   start_from: start_from,
                   receiver: receiver,
                   distro: distro,
                   start_time: start_time}
    init_get_request(state)
    {:stop, :normal, state}
  end

  defp url_without_host(url) do
    url |> to_string |> URI.path_to_segments |> Enum.drop(-2) |> Enum.reverse |> Path.join
  end

end
