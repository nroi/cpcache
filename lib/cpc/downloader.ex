defmodule Cpc.Downloader do
  require Logger
  use GenServer
  alias Cpc.Utils
  alias Cpc.Downloader, as: Dload
  defstruct url: nil,
            save_to: nil,
            start_from: nil,
            receiver: nil,
            arch: nil,
            req_id: nil,
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

  def start_link(url, save_to, receiver, arch, start_from \\ nil) do
    GenServer.start_link(__MODULE__, {to_charlist(url),
                                      to_charlist(save_to),
                                      receiver,
                                      arch,
                                      start_from})
  end

  def init({url, save_to, receiver, arch, start_from}) do
    send self(), :init
    Process.flag(:trap_exit, true)
    {:ok, {url, save_to, receiver, arch, start_from}}
  end

  def init_get_request(url, save_to, start_from) do
    headers = case start_from do
                nil -> []
                0 -> []
                rs -> [{"Range", "bytes=#{rs}-"}]
              end
    opts = [save_response_to_file: {:append, save_to}, stream_to: {self(), :once}]
    {:ibrowse_req_id, req_id} = :ibrowse.send_req(url, headers, :get, [], opts, :infinity)
    req_id
  end

  def handle_info(:init, {url, save_to, receiver, arch, start_from}) do
    start_time = :erlang.system_time(:micro_seconds)
    req_id = init_get_request(url, save_to, start_from)
    state = %Dload{url: url,
                   save_to: save_to,
                   start_from: start_from,
                   receiver: receiver,
                   arch: arch,
                   req_id: req_id}
    {:noreply, %{state | start_time: start_time}}
  end

  def handle_info({:ibrowse_async_headers, req_id, '404', _}, state = %Dload{}) do
    send state.receiver, :not_found
    :ok = :ibrowse.stream_close(req_id)
    Logger.warn "Download of URL #{state.url} has failed: 404"
    {:stop, :normal, state}
  end

  def handle_info({:ibrowse_async_headers, req_id, '200', headers}, state = %Dload{}) do
    headers = Utils.headers_to_lower(headers)
    content_length = :proplists.get_value("content-length", headers) |> String.to_integer
    Logger.debug "Content-length: #{content_length}"
    send state.receiver, {:content_length, content_length}
    path = url_without_host(state.url)
    {:atomic, :ok} = :mnesia.transaction(fn ->
      :mnesia.write({ContentLength, {state.arch, Path.basename(path)}, content_length})
    end)
    :ok = :ibrowse.stream_next(req_id)
    {:noreply, %{state |
                 content_length: content_length,
                 status: :ok}}
  end

  # When content-ranges are used, the server replies with the length of the partial file. However,
  # we need to return the content length of the entire file to the client.
  def handle_info({:ibrowse_async_headers, req_id, '206', headers}, state = %Dload{}) do
    headers = Utils.headers_to_lower(headers)
    content_length = :proplists.get_value("content-length", headers) |> String.to_integer
    Logger.debug "Content-length: #{content_length}"
    header_line = :proplists.get_value("content-range", headers)
    [_, full_length] = String.split(header_line, "/")
    full_content_length = String.to_integer(full_length)
    send state.receiver, {:content_length, full_content_length}
    path = url_without_host(state.url)
    {:atomic, :ok} = :mnesia.transaction(fn ->
      :mnesia.write({ContentLength, path, full_content_length})
    end)
    :ok = :ibrowse.stream_next(req_id)
    {:noreply, %{state |
                 content_length: content_length,
                 status: :ok}}
  end

  def handle_info({:ibrowse_async_headers, req_id, '302', headers}, state = %Dload{}) do
    :ok = :ibrowse.stream_next(req_id)
    headers = Utils.headers_to_lower(headers)
    location = to_charlist(:proplists.get_value("location", headers))
    _ = Logger.debug "Redirected to location #{location}"
    {:noreply, %{state | url: location, req_id: req_id, status: {:redirect, location}}}
  end

  def handle_info({:ibrowse_async_response, _req_id, []}, state = %Dload{status: {:redirect, _}}) do
    {:noreply, state}
  end

  def handle_info({:ibrowse_async_response_end, req_id},
                  state = %Dload{status: {:redirect, location}}) do
    :ok = :ibrowse.stream_close(req_id)
    start_time = :erlang.system_time(:micro_seconds)
    req_id = init_get_request(location, state.save_to, state.start_from)
    {:noreply, %{state | status: :unknown, req_id: req_id, start_time: start_time}}
  end

  def handle_info({:ibrowse_async_response, req_id, {:file, _}}, state) do
    # ibrowse informs us where the file has been saved to. Ignored, we have other mechanisms in
    # place to detect when the file has been downloaded completely.
    :ok = :ibrowse.stream_next(req_id)
    {:noreply, state}
  end

  def handle_info({:ibrowse_async_response_end, req_id}, state = %Dload{status: :ok}) do
    :ok = :ibrowse.stream_close(req_id)
    now = :erlang.system_time(:micro_seconds)
    diff = now - state.start_time
    _ = Logger.debug "Download of URL #{state.url} to file #{state.save_to} has completed."
    speed = bandwidth_to_human_readable(state.content_length, diff)
    secs = Float.round(diff / 1000000, 2)
    _ = Logger.debug "Received #{state.content_length} bytes in #{secs} seconds (#{speed})."
    host = URI.parse(to_string(state.url)).host
    {:atomic, :ok} = :mnesia.transaction(fn ->
      :mnesia.write({DownloadSpeed, host, state.content_length, state.start_time, diff})
    end)
    {:stop, :normal, state}
  end

  def handle_info({:ibrowse_async_response_end, req_id}, state = %Dload{status: :redirect}) do
    :ok = :ibrowse.stream_close(req_id)
    {:noreply, state}
  end

  def terminate(status, %Dload{req_id: req_id}) do
    Logger.debug "Downloader exits with status #{inspect status}."
    # Close stream in case the download is still active.
    # Otherwise, we would have an active download without supervision from the serializer, so we
    # might end up writing to the same filename with multiple processes.
    _ = :ibrowse.stream_close(req_id)
  end

  defp url_without_host(url) do
    url |> to_string |> URI.path_to_segments |> Enum.drop(-2) |> Enum.reverse |> Path.join
  end

end
