defmodule Cpc.Downloader do
  require Logger
  use GenServer
  alias Cpc.Utils
  alias Cpc.Downloader, as: Dload
  defstruct url: nil,
            save_to: nil,
            start_from: nil,
            receiver: nil,
            req_id: nil

  # Process for downloading the given URL starting from byte start_from to the filename at path
  # save_to.

  def start_link(url, save_to, receiver, start_from \\ nil, append \\ false) do
    GenServer.start_link(__MODULE__, {to_charlist(url),
                                      to_charlist(save_to),
                                      receiver,
                                      start_from,
                                      append})
  end

  def init({url, save_to, receiver, start_from, append}) do
    send self(), :init
    Process.flag(:trap_exit, true)
    {:ok, {url, save_to, receiver, start_from, append}}
  end

  def handle_info(:init, {url, save_to, receiver, start_from, append}) do
    headers = case start_from do
      nil ->
        []
      rs -> [{"Range", "bytes=#{rs}-"}]
    end
    srtf = case append do
      false -> save_to
      true ->  {:append, save_to}
    end
    opts = [save_response_to_file: srtf, stream_to: {self(), :once}]
    {:ibrowse_req_id, req_id} = :ibrowse.send_req(url, headers, :get, [], opts, :infinity)
    state = %Dload{url: url,
                   save_to: save_to,
                   start_from: start_from,
                   receiver: receiver,
                   req_id: req_id}
    {:noreply, state}
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
    send state.receiver, {:content_length, content_length}
    path = url_without_host(state.url)
    Logger.debug "Write content length #{content_length} for path #{path} to cache."
    {:atomic, :ok} = :mnesia.transaction(fn ->
      :mnesia.write({ContentLength, path, content_length})
    end)
    :ok = :ibrowse.stream_next(req_id)
    {:noreply, state}
  end

  # When content-ranges are used, the server replies with the length of the partial file. However,
  # we need to return the content length of the entire file to the client.
  def handle_info({:ibrowse_async_headers, req_id, '206', headers}, state = %Dload{}) do
    headers = Utils.headers_to_lower(headers)
    header_line = :proplists.get_value("content-range", headers)
    [_, full_length] = String.split(header_line, "/")
    full_content_length = String.to_integer(full_length)
    send state.receiver, {:content_length, full_content_length}
    path = url_without_host(state.url)
    Logger.debug "Write content length #{full_content_length} for path #{path} to cache."
    {:atomic, :ok} = :mnesia.transaction(fn ->
      :mnesia.write({ContentLength, path, full_content_length})
    end)
    :ok = :ibrowse.stream_next(req_id)
    {:noreply, state}
  end

  def handle_info({:ibrowse_async_response, req_id, {:file, _}}, state) do
    # ibrowse informs us where the file will be saved to — ignored, since we have chosen the
    # filename ourselves.
    :ok = :ibrowse.stream_next(req_id)
    {:noreply, state}
  end

  def handle_info({:ibrowse_async_response_end, req_id}, state = %Dload{}) do
    :ok = :ibrowse.stream_close(req_id)
    Logger.debug "Download of URL #{state.url} to file #{state.save_to} has completed."
    {:stop, :normal, state}
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
