defmodule Cpc.ClientRequest do
  alias Cpc.ClientRequest, as: CR
  alias Cpc.Utils
  require Logger
  use GenServer
  defstruct sock: nil,
            arch: nil,
            serializer: nil,
            purger: nil,
            action: nil,
            req_id: nil,
            timer_ref: nil

  def start_link(serializer, arch, sock, purger) do
    GenServer.start_link(__MODULE__, %CR{sock: sock,
                                         arch: arch,
                                         serializer: serializer,
                                         purger: purger,
                                         action: {:recv_header, %{uri: nil, range_start: nil}}})
  end

  # TODO we still have two downloads if one client downloads the file from start, the other client
  # is using content ranges.

  defp get_filename(uri, arch) do
    [{^arch, %{cache_directory: cache_dir, url: mirror}}] = :ets.lookup(:cpc_config, arch)
    filename = Path.join(cache_dir, uri)
    dirname = Path.dirname(filename)
    basename = Path.basename(filename)
    is_database = String.ends_with?(basename, ".db")
    {partial_file_exists, complete_file_exists} = case is_database do
      true -> {false, false}
      false ->
        case File.stat(Path.join(dirname, basename)) do
          {:error, :enoent} -> {false, false}
          {:ok, %File.Stat{size: size}} ->
            case content_length(uri, arch) do
              ^size ->             {true, true}
              cl when cl > size -> {true, false}
            end
        end
    end
    case {is_database, complete_file_exists, partial_file_exists} do
      {true, _, _} ->
        {:database, Path.join(mirror, uri)}
      {false, false, false} ->
        {:not_found, Path.join([dirname, basename])}
      {false, true, _} ->
        {:complete_file, filename}
      {false, false, true} ->
        {:partial_file, Path.join([dirname, basename])}
    end
  end

  defp header(full_content_length, range_start) do
    content_length = case range_start do
      nil -> full_content_length
      rs  -> full_content_length - rs
    end
    content_range_line = case range_start do
      nil ->
        ""
      rs ->
        range_end = full_content_length - 1
        "Content-Range: #{rs}-#{range_end}/#{full_content_length}\r\n"
    end
    date = to_string(:httpd_util.rfc1123_date)
    "HTTP/1.1 200 OK\r\n" <>
    "Server: cpc\r\n" <>
    "Date: #{date}\r\n" <>
    "Content-Type: application/octet-stream\r\n" <>
    "Content-Length: #{content_length}\r\n" <>
    content_range_line <>
    "\r\n"
  end

  defp header_301(location) do
    date = to_string(:httpd_util.rfc1123_date)
    "HTTP/1.1 301 Moved Permanently\r\n" <>
    "Server: cpc\r\n" <>
    "Date: #{date}\r\n" <>
    "Content-Type: text/html\r\n" <>
    "Content-Length: 0\r\n" <>
    "Location: #{location}\r\n" <>
    "\r\n"
  end

  defp header_404() do
    date = to_string(:httpd_util.rfc1123_date)
    "HTTP/1.1 404 Not Found\r\n" <>
    "Server: cpc\r\n" <>
    "Date: #{date}\r\n" <>
    "Content-Length: 0\r\n" <>
    "\r\n"
  end

  # Given the URI requested by the user, returns the URI we need to send our HTTP request to
  def mirror_uri(uri, arch) do
    [{_, %{url: mirror}}] = :ets.lookup(:cpc_config, arch)
    mirror |> String.replace_suffix("/", "") |> Path.join(uri)
  end

  # Given the requested URI, fetch the full content-length from the server.
  # req_uri must be the URI as requested by the user, not the URI that will be used to GET the file
  # via HTTP.
  def content_length(req_uri, arch) do
    db_result = :mnesia.transaction(fn ->
      :mnesia.read({ContentLength, req_uri})
    end)
    result = case db_result do
      {:atomic, [{ContentLength, ^req_uri, content_length}]} -> {:ok, content_length}
      {:atomic, []} -> :not_found
    end
    case result do
      {:ok, content_length} ->
        Logger.debug "Retrieve content-length for #{req_uri} from cache."
        content_length
      :not_found ->
        Logger.debug "Retrieve content-length for #{req_uri} via HTTP HEAD request."
        uri = mirror_uri(req_uri, arch)
        headers = case :httpc.request(:head, {to_charlist(uri), []},[],[]) do
          {:ok, {{_, 200, 'OK'}, headers, _}} -> Utils.headers_to_lower(headers)
        end
        content_length = :proplists.get_value("content-length", headers) |> String.to_integer
        {:atomic, :ok} = :mnesia.transaction(fn ->
          :mnesia.write({ContentLength, req_uri, content_length})
        end)
        content_length
    end
  end

  defp serve_via_http(filename, state, hs) do
    _ = Logger.info "Serve file #{filename} via HTTP."
    url = mirror_uri(hs.uri, state.arch)
    Cpc.Downloader.start_link(url, filename, self(), hs.range_start)
    receive do
      {:content_length, content_length} ->
        reply_header = header(content_length, hs.range_start)
        :ok = :gen_tcp.send(state.sock, reply_header)
        _ = Logger.debug "Sent header: #{reply_header}"
        :ok = Cpc.Filewatcher.waitforfile(filename)
        file = File.open!(filename, [:read, :raw])
        {:ok, _} = Cpc.Filewatcher.start_link(self(), filename, content_length)
        action = {:filewatch, {file, filename}, content_length, 0}
        {:noreply, %{state | action: action}}
      :not_found ->
        reply_header = header_404()
        :ok = :gen_tcp.send(state.sock, reply_header)
        {:noreply, %{state | action: {:recv_header, %{uri: nil, range_start: nil}}}}
    end
  end

  defp serve_via_redirect(db_url, state) do
    _ = Logger.info "Serve database file #{db_url} via http redirect."
    :ok = :gen_tcp.send(state.sock, header_301(db_url))
    {:noreply, %{state | req_id: nil, action: {:recv_header, %{uri: nil, range_start: nil}}}}
  end

  defp serve_via_cache(filename, state, range_start) do
    _ = Logger.info "Serve file from cache: #{filename}"
    content_length = File.stat!(filename).size
    reply_header = header(content_length, range_start)
    :ok = :gen_tcp.send(state.sock, reply_header)
    case range_start do
      nil ->
        {:ok, ^content_length} = :file.sendfile(filename, state.sock)
      rs when rs == content_length ->
        Logger.warn "File is already fully retrieved by client."
        :ok
      rs when rs < content_length ->
        Logger.debug "Send partial file, from #{rs} until end."
        f = File.open!(filename, [:read, :raw])
        {:ok, _} = :file.sendfile(f, state.sock, range_start, content_length - rs, [])
        :ok = File.close(f)
    end
    _ = Logger.debug "Download from cache complete."
    {:noreply, %{state | req_id: nil, action: {:recv_header, %{uri: nil, range_start: nil}}}}
  end

  defp serve_via_growing_file(filename, state, range_start) do
    %CR{action: {:recv_header, %{uri: uri}}} = state
    full_content_length = content_length(uri, state.arch)
    {:ok, _} = GenServer.start_link(Cpc.Filewatcher, {self(), filename, full_content_length})
    Logger.info "File #{filename} is already being downloaded, initiate download from " <>
                "growing file."
    reply_header = header(full_content_length, range_start)
    :ok = :gen_tcp.send(state.sock, reply_header)
    :ok = Cpc.Filewatcher.waitforfile(filename)
    file = File.open!(filename, [:read, :raw])
    {:noreply, %{state | action: {:filewatch, {file, filename}, full_content_length, 0}}}
  end

  defp serve_via_cache_and_http(state, filename, hs) do
    # A partial file already exists on the filesystem, but this file was saved in a previous
    # download process that did not finish -- the file is not in the process of being downloaded.
    # We serve the beginning of the file from the cache, if possible. If the requester requested a
    # range that exceeds the amount of bytes we have saved for this file, everything is downloaded
    # via HTTP.
    filesize = File.stat!(filename).size
    retrieval_start_method = case hs.range_start do
      nil -> {:file, 0} # send file starting from 0th byte.
      rs  ->
        cond do
          rs <  filesize -> {:file, hs.range_start}
          rs >= filesize -> {:http, hs.range_start}
        end
    end
    raw_file = File.open!(filename, [:read, :raw])
    Logger.debug "Start of requested content-range: #{hs.range_start}"
    {start_http_from_byte, send_from_cache} = case retrieval_start_method do
      {:file, from} ->
        send_ = fn ->
          {:ok, _} = :file.sendfile(raw_file, state.sock, from, filesize - from, [])
        end
        {filesize, send_}
      {:http, from} ->
        {from, fn -> :ok end}
    end
    Logger.debug "Start HTTP download from byte #{start_http_from_byte}"
    range_start = hs.range_start
    case content_length(hs.uri, state.arch) do
      cl when cl == filesize ->
        Logger.warn "The entire file has already been downloaded by the server."
        serve_via_cache(filename, state, hs.range_start)
      cl when cl == range_start ->
        # The client requested a content range, although he already has the entire file.
        reply_header = header(cl, hs.range_start)
        :ok = :gen_tcp.send(state.sock, reply_header)
        _ = Logger.debug "Sent header: #{reply_header}"
        Logger.warn "File is already fully retrieved by client."
        {:noreply, %{state | req_id: nil,
                             action: {:recv_header, %{uri: nil, range_start: nil}}}}
      _ ->
        [{_, %{url: mirror}}] = :ets.lookup(:cpc_config, state.arch)
        url = Path.join(mirror, hs.uri)
        Cpc.Downloader.start_link(url, filename, self(), start_http_from_byte, true)
        receive do
          {:content_length, content_length} ->
            file = File.open!(filename, [:read, :raw])
            reply_header = header(content_length, hs.range_start)
            :ok = :gen_tcp.send(state.sock, reply_header)
            _ = Logger.debug "Sent header: #{reply_header}"
            send_from_cache.()
            :ok = File.close(raw_file)
            {:ok, _} = GenServer.start_link(Cpc.Filewatcher, {self(), filename, content_length})
            action = {:filewatch, {file, filename}, content_length, start_http_from_byte}
            {:noreply, %{state | action: action}}
          :not_found ->
            reply_header = header_404()
            :ok = :gen_tcp.send(state.sock, reply_header)
            _ = Logger.debug "Sent header: #{reply_header}"
            {:noreply, %{state | req_id: nil,
                                 action: {:recv_header, %{uri: nil, range_start: nil}}}}
        end
    end
  end

  defp serve_via_partial_file(state, filename, hs) do
    # The requested file already exists, but its size is smaller than the content length
    send state.serializer, {self(), :state?, filename}
    receive do
      :downloading ->
        serve_via_growing_file(filename, state, hs.range_start)
      :unknown ->
        _ = Logger.info "Serve file #{filename} partly via cache, partly via HTTP."
        serve_via_cache_and_http(state, filename, hs)
    end
  end

  def handle_info({:http, _, {:http_request, :GET, {:abs_path, path}, _}},
                  state = %CR{action: {:recv_header, hs}}) do
    uri = case path do
      "/" <> rest -> URI.decode(rest)
    end
    {:noreply, %{state | action: {:recv_header, %{hs | uri: uri}}}}
  end


  def handle_info({:http, _, {:http_header, _, :Range, _, range}},
                  state = %CR{action: {:recv_header, hs}}) do
    range_start = case range do
      "bytes=" <> rest ->
        {start, "-"} = Integer.parse(rest)
        start
    end
    {:noreply, %{state | action: {:recv_header, %{hs | range_start: range_start}}}}
  end

  def handle_info({:http, _, :http_eoh}, state = %CR{action: {:recv_header, hs}}) do
    Logger.debug "Received end of header."
    case get_filename(hs.uri, state.arch) do
      {:database, db_url} ->
        serve_via_redirect(db_url, state)
      {:complete_file, filename} ->
        serve_via_cache(filename, state, hs.range_start)
      {:partial_file, filename} ->
        serve_via_partial_file(state, filename, hs)
      {:not_found, filename} ->
        send state.serializer, {self(), :state?, filename}
        receive do
          :downloading ->
            Logger.debug "Status of file is: :downloading"
            serve_via_growing_file(filename, state, hs.range_start)
          :unknown ->
            Logger.debug "Status of file is: :unknown"
            serve_via_http(filename, state, hs)
        end
    end
  end

  def handle_info({:ibrowse_async_response, _req_id, {:error, error}}, _state) do
    raise "Error while processing get request: #{inspect error}"
  end

  def handle_info({:ibrowse_async_response, req_id, {:file, _filename}}, state) do
    :ibrowse.stream_next(req_id)
    # ibrowse informs us of the filename where the download has been saved to. We can ignore this,
    # since we have set the filename ourselves (instead of having a random filename chosen by
    # ibrowse).
    {:noreply, state}
  end

  def handle_info({:ibrowse_async_response_end, req_id},
                  state = %CR{action: {:filewatch, {f, n}, content_length, size}}) do
    :ok = :ibrowse.stream_close(req_id)
    finalize_download_from_growing_file(state, f, n, size, content_length)
    {:noreply, %{state | req_id: nil,
                         action: {:recv_header, %{uri: nil, range_start: nil}}}}
  end

  def handle_info({:ibrowse_async_response_end, _req_id}, state) do
    # Safe to ignore: Sometimes, we receive :file_complete before ibrowse informs us that the GET
    # request has completed.
    {:noreply, state}
  end


  def handle_info({:tcp_closed, _}, state = %CR{action: {:filewatch, {_, n}, _, _}}) do
    Logger.info "Connection closed by client during data transfer. File #{n} is incomplete."
    :ok = :ibrowse.stream_close(state.req_id)
    {:stop, :normal, nil}
  end

  def handle_info({:http, _sock, http_packet}, state) do
    Logger.debug "Ignored: #{inspect http_packet}"
    {:noreply, state}
  end

  def handle_info({:tcp_closed, _sock}, _state) do
    Logger.debug "Socket closed by client."
    {:stop, :normal, nil}
  end

  def handle_cast({:filesize_increased, {n1, prev_size, new_size}},
              state = %CR{action: {:filewatch, {f, n2}, content_length, _size}}) when n1 == n2 do
    {:ok, _} = :file.sendfile(f, state.sock, prev_size, new_size - prev_size, [])
    {:noreply, %{state | action: {:filewatch, {f, n2}, content_length, new_size}}}
  end

  def handle_cast({:file_complete, {n1, _prev_size, new_size}},
              state = %CR{action: {:filewatch, {f, n2}, content_length, size}}) when n1 == n2 do
    ^new_size = content_length
    finalize_download_from_growing_file(state, f, n2, size, content_length)
    {:noreply, %{state | req_id: nil,
                         action: {:recv_header, %{uri: nil, range_start: nil}}}}
  end

  def handle_cast({:file_complete, {_filename, _prev_size, _new_size}}, state) do
    # Save to ignore: sometimes we catch the file completion via ibrowse_async_response_end, but the
    # timer still informs us that the file has completed.
    Logger.debug "Ignore file completion."
    {:noreply, state}
  end

  def handle_cast({:filesize_increased, {_filename, _prev_size, _new_size}}, state) do
    # Can be ignored for the same reasons as :file_complete:
    # timer still informs us that the file has completed.
    Logger.debug "Ignore file size increase."
    {:noreply, state}
  end

  defp finalize_download_from_growing_file(state, f, n, size, content_length) do
    Logger.debug "Download from growing file complete."
    {:ok, _} = :file.sendfile(f, state.sock, size, content_length - size, [])
    Logger.debug "Sendfile has completed."
    :ok = File.close(f)
    :ok = GenServer.cast(state.serializer, {:download_ended, n, self()})
    Logger.debug "File is closed."
    ^content_length = File.stat!(n).size
    :ok = GenServer.cast(state.purger, :purge)
  end

  # TODO: check the reason. If it's not :normal, check the state. If the header has not yet been
  # sent to the client, send a 500 response instead of just failing.
  # def terminate(reason, state) do
  # end

end