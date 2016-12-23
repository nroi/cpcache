defmodule Cpc.Downloader do
  alias Cpc.Downloader, as: Dload
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
    GenServer.start_link(__MODULE__, %Dload{sock: sock,
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
    complete_file_exists = Enum.member?(File.ls!(dirname), basename)
    partial_file_exists = Enum.member?(File.ls!(Path.join(dirname, "downloads")), basename)
    is_database = String.ends_with?(basename, ".db")
    case {is_database, complete_file_exists, partial_file_exists} do
      {true, _, _} ->
        {:database, Path.join(mirror, uri)}
      {false, false, false} ->
        {:not_found, Path.join([dirname, "downloads", basename])}
      {false, true, _} ->
        {:complete_file, filename}
      {false, false, true} ->
        {:partial_file, Path.join([dirname, "downloads", basename])}
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

  # Given a filename, fetch the full content-length from the server.
  def content_length(req_uri, arch) do
    uri = mirror_uri(req_uri, arch)
    headers = case :httpc.request(:head, {to_charlist(uri), []},[],[]) do
      {:ok, {{_, 200, 'OK'}, headers, _}} -> headers_to_lower(headers)
    end
    :proplists.get_value("content-length", headers) |> String.to_integer
  end

  defp serve_via_http(filename, state, hs) do
    _ = Logger.info "Serve file #{filename} via HTTP."
    url = mirror_uri(hs.uri, state.arch)
    headers = case hs.range_start do
      nil ->
        []
      rs -> [{"Range", "bytes=#{rs}-"}]
    end
    opts = [save_response_to_file: to_charlist(filename), stream_to: {self(), :once}]
    {:ibrowse_req_id, req_id} = :ibrowse.send_req(to_charlist(url), headers, :get, [], opts, :infinity)
    # TODO we probably don't need to get the content length via mailbox.
    case content_length_from_mailbox() do
      {:ok, {_, full_content_length}} ->
        reply_header = header(full_content_length, hs.range_start)
        :ok = :gen_tcp.send(state.sock, reply_header)
        _ = Logger.debug "Sent header: #{reply_header}"
        # TODO for debugging purposes, just to see how large the timeout should be set.
        {microsecs, :ok} = :timer.tc(Cpc.Filewatcher, :wait_until_file_exists, [filename])
        Logger.debug "Waited #{microsecs / 1000} ms for file creation."
        file = File.open!(filename, [:read, :raw])
        {:ok, _} = GenServer.start_link(Cpc.Filewatcher, {self, filename, full_content_length})
        action = {:filewatch, {file, filename}, full_content_length, 0}
        {:noreply, %{state | req_id: req_id, action: action}}
      {:error, :not_found} ->
        Logger.warn "Send not found to serializer."
        send state.serializer, {self(), :not_found}
        reply_header = header_404()
        :ok = :gen_tcp.send(state.sock, reply_header)
        {:noreply, %{state | req_id: nil, action: {:recv_header, %{uri: nil, range_start: nil}}}}
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
      rs ->
        Logger.debug "Send partial file, from #{rs} until end."
        f = File.open!(filename, [:read, :raw])
        {:ok, _} = :file.sendfile(f, state.sock, range_start, content_length - rs, [])
        :ok = File.close(f)
    end
    _ = Logger.debug "Download from cache complete."
    {:noreply, %{state | req_id: nil, action: {:recv_header, %{uri: nil, range_start: nil}}}}
  end

  defp serve_via_growing_file(filename, state, range_start) do
    %Dload{action: {:recv_header, %{uri: uri}}} = state
    full_content_length = content_length(uri, state.arch)
    {:ok, _} = GenServer.start_link(Cpc.Filewatcher, {self, filename, full_content_length})
    Logger.info "File #{filename} is already being downloaded, initiate download from " <>
                "growing file."
    reply_header = header(full_content_length, range_start)
    :ok = :gen_tcp.send(state.sock, reply_header)
    {microsecs, :ok} = :timer.tc(Cpc.Filewatcher, :wait_until_file_exists, [filename])
    Logger.debug "Waited #{microsecs / 1000} ms for file creation."
    file = File.open!(filename, [:read, :raw])
    {:noreply, %{state | action: {:filewatch, {file, filename}, full_content_length, 0}}}
  end

  defp serve_via_cache_http(state, filename, hs) do
    # A partial file already exists on the filesystem, but this file was saved in a previous
    # download process that did not finish -- the file is not in the process of being downloaded.
    # We serve the beginning of the file from the cache, if possible. If the requester requested a
    # range that exceeds the amount of bytes we have saved for this file, everything is downloaded
    # via HTTP.
    send state.serializer, {self(), :state?, filename}
    receive do
      :downloading ->
        serve_via_growing_file(filename, state, hs.range_start)
      :unknown ->
        _ = Logger.info "Serve file #{filename} partly via cache, partly via HTTP."
        filesize = File.stat!(filename).size
        retrieval_start_method = case hs.range_start do
          nil -> {:file, 0} # send file starting from 0th byte.
          rs  ->
            case rs < filesize do
              true  -> {:file, hs.range_start}
              false -> {:http, hs.range_start}
            end
        end
        raw_file = File.open!(filename, [:read, :raw])
        {start_http_from_byte, send_from_cache} = case retrieval_start_method do
          {:file, from} ->
            send_ = fn ->
              {:ok, _} = :file.sendfile(raw_file, state.sock, from, filesize - from, [])
            end
            {filesize, send_}
          {:http, from} ->
            {from, fn -> :ok end}
        end
        headers = [{"Range", "bytes=#{start_http_from_byte}-"}]
        [{_, %{url: mirror}}] = :ets.lookup(:cpc_config, state.arch)
        url = Path.join(mirror, hs.uri)
        opts = [save_response_to_file: {:append, to_charlist(filename)}, stream_to: {self(), :once}]
        {:ibrowse_req_id, req_id} = :ibrowse.send_req(to_charlist(url), headers, :get, [], opts)
        case content_length_from_mailbox() do
          {:ok, {_, full_content_length}} ->
            file = File.open!(filename, [:read, :raw])
            reply_header = header(full_content_length, hs.range_start)
            :ok = :gen_tcp.send(state.sock, reply_header)
            _ = Logger.debug "Sent header: #{reply_header}"
            send_from_cache.()
            :ok = File.close(raw_file)
            {:ok, _} = GenServer.start_link(Cpc.Filewatcher, {self, filename, full_content_length})
            action = {:filewatch, {file, filename}, full_content_length, start_http_from_byte}
            {:noreply, %{state | req_id: req_id, action: action}}
          {:error, :not_found} ->
            Logger.warn "Send not found to serializer."
            send state.serializer, {self(), :not_found}
            reply_header = header_404()
            :ok = :gen_tcp.send(state.sock, reply_header)
            _ = Logger.debug "Sent header: #{reply_header}"
            {:noreply, %{state | req_id: nil,
                                 action: {:recv_header, %{uri: nil, range_start: nil}}}}
          {:error, {:range_not_satisfiable, filesize}} ->
            case File.stat!(filename).size do
              ^filesize ->
                send state.serializer, {self(), :complete}
                Logger.warn "Server replied with 416: Range not satisfiable, probably " <>
                "because no symlink was set after the file was downloaded. Set symlink now."
                receive do
                  {:ibrowse_async_response, _req_id, body} ->
                    Logger.debug "Ignore response body: #{inspect body}"
                end
                set_symlink(filename)
                serve_via_cache(filename, state, hs.range_start)
              _size ->
                raise("Server replied with 416: Range not satisfiable")
            end
        end
    end
  end

  def handle_info({:http, _, {:http_request, :GET, {:abs_path, path}, _}},
                  state = %Dload{action: {:recv_header, hs}}) do
    uri = case path do
      "/" <> rest -> URI.decode(rest)
    end
    {:noreply, %{state | action: {:recv_header, %{hs | uri: uri}}}}
  end


  def handle_info({:http, _, {:http_header, _, :Range, _, range}},
                  state = %Dload{action: {:recv_header, hs}}) do
    range_start = case range do
      "bytes=" <> rest ->
        {start, "-"} = Integer.parse(rest)
        start
    end
    {:noreply, %{state | action: {:recv_header, %{hs | range_start: range_start}}}}
  end

  def handle_info({:http, _, :http_eoh}, state = %Dload{action: {:recv_header, hs}}) do
    case get_filename(hs.uri, state.arch) do
      {:database, db_url} ->
        serve_via_redirect(db_url, state)
      {:complete_file, filename} ->
        serve_via_cache(filename, state, hs.range_start)
      {:partial_file, filename} ->
        serve_via_cache_http(state, filename, hs)
      {:not_found, filename} ->
        send state.serializer, {self(), :state?, filename}
        receive do
          :downloading ->
            serve_via_growing_file(filename, state, hs.range_start)
          :unknown ->
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
    # since we have set the filename ourself (instead of having a random filename chosen by
    # ibrowse).
    {:noreply, state}
  end

  def handle_info({:ibrowse_async_response_end, req_id},
                  state = %Dload{action: {:filewatch, {f, n}, content_length, size}}) do
    :ok = :ibrowse.stream_close(req_id)
    Logger.debug "Call finalize from async_response_end"
    finalize_download_from_growing_file(state, f, n, size, content_length)
    {:noreply, %{state | req_id: nil,
                         action: {:recv_header, %{uri: nil, range_start: nil}}}}
  end

  def handle_info({:ibrowse_async_response_end, _req_id}, state) do
    # Safe to ignore: Sometimes, we receive :file_complete before ibrowse informs us that the GET
    # request has completed.
    {:noreply, state}
  end


  def handle_info({:tcp_closed, _}, state = %Dload{action: {:filewatch, {_, n}, _, _}}) do
    Logger.info "Connection closed by client during data transfer. File #{n} is incomplete."
    :ok = :ibrowse.stream_close(state.req_id)
    {:stop, :normal, nil}
  end

  def handle_info({:http, _sock, http_packet}, state) do
    Logger.debug "Ignored: #{inspect http_packet}"
    {:noreply, state}
  end

  def handle_info({:tcp_closed, _}, :sock_closed) do
    Logger.info "Connection closed."
    {:stop, :normal, nil}
  end

  def handle_info({:ibrowse_async_response_end, _req_id}, :sock_closed) do
    {:stop, :normal, nil}
  end

  def handle_info({:tcp_closed, _sock}, _state) do
    Logger.debug "Socket closed by client."
    {:stop, :normal, nil}
  end

  # TODO do we still need the content length and size?
  def handle_cast({:filesize_increased, {n1, prev_size, new_size}},
              state = %Dload{action: {:filewatch, {f, n2}, content_length, size}}) when n1 == n2 do
    {:ok, _} = :file.sendfile(f, state.sock, prev_size, new_size - prev_size, [])
    {:noreply, %{state | action: {:filewatch, {f, n2}, content_length, new_size}}}
  end

  def handle_cast({:file_complete, {n1, prev_size, new_size}},
              state = %Dload{action: {:filewatch, {f, n2}, content_length, size}}) when n1 == n2 do
    Logger.debug "Call finalize from handle_info(:timer, …)"
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
    # Can be ignored for the same reasons as :file_complete
    # timer still informs us that the file has completed.
    Logger.debug "Ignore file size increase."
    {:noreply, state}
  end

  defp finalize_download_from_growing_file(state, f, n, size, content_length) do
    Logger.debug "Download from growing file complete."
    Logger.debug "Content-length: #{content_length}, size: #{size}"
    {:ok, _} = :file.sendfile(f, state.sock, size, content_length - size, [])
    Logger.debug "Sendfile has completed."
    :ok = File.close(f)
    :ok = GenServer.cast(state.serializer, {:download_ended, n, self})
    Logger.debug "File is closed."
    ^content_length = File.stat!(n).size
    Logger.debug "Assertion checked."
    set_symlink(n)
    _ = Logger.debug "Symlink set."
    :ok = GenServer.cast(state.purger, :purge)
  end

  defp content_length_from_mailbox() do
    result = receive do
      {:ibrowse_async_headers, req_id, '200', headers} ->
        :ibrowse.stream_next(req_id)
        Logger.debug "Received 200, download entire file via HTTP."
        {:ok, {:complete, headers}}
      {:ibrowse_async_headers, req_id, '206', headers} ->
        :ibrowse.stream_next(req_id)
        Logger.debug "Received 206, download partial file via HTTP."
        {:ok, {:partial, headers}}
      {:ibrowse_async_headers, _req_id, '404', _} ->
        Logger.warn "Mirror returned 404."
        {:error, :not_found}
      {:ibrowse_async_headers, _req_id, '416', headers} ->
        # range not satisfiable -- this may happen when a complete file is stored inside the
        # downloads directory, but for some reason, the corresponding symlink was not created.
        [_, file_size_str] = headers
                             |> headers_to_lower
                             |> Enum.find_value(fn
                                  {"content-range", "bytes " <> rest} -> rest
                                  _ -> false
                             end)
                             |> String.split("/")
        file_size = String.to_integer(file_size_str)
        {:error, {:range_not_satisfiable, file_size}}
      {:ibrowse_async_headers, _, status, _headers} ->
        raise "Expected HTTP response 200, got instead: #{inspect status}"
    after 3000 ->
        raise "Timeout while waiting for response to GET request."
    end
    with {:ok, {status, header}} <- result do
      header = headers_to_lower(header)
      content_length = :proplists.get_value("content-length", header) |> String.to_integer
      full_content_length = case status do
        :complete ->
          content_length
        :partial ->
          header_line = :proplists.get_value("content-range", header)
          [_, full_length] = String.split(header_line, "/")
          String.to_integer(full_length)
      end
      {:ok, {content_length, full_content_length}}
    end
  end

  defp headers_to_lower(headers) do
    Enum.map(headers, fn {key, val} ->
      {key |> to_string |> String.downcase, val |> to_string |> String.downcase}
    end)
  end

  defp set_symlink(filename) do
    basename = Path.basename(filename)
    dirname = Path.dirname(filename)
    download_dir_basename = filename |> Path.dirname |> Path.basename
    target = Path.join(download_dir_basename, basename)
    Logger.debug "Run ln command…"
    # Set symlink, unless it already exists. It may already be set if this
    # function was called while the download had already been initiated by
    # another process.
    result = System.cmd("/usr/bin/ln", ["-s", target, basename],
                        cd: Path.join(dirname, ".."),
                        stderr_to_stdout: true)
    Logger.debug "Done. evaluate result…"
    case result do
      {"", 0} -> :ok
      {output, 1} ->
        if String.ends_with?(output, "File exists\n") do
          Logger.debug "Symlink already exists."
          :ok
        else
          raise output
        end
    end
    Logger.debug "Done."
  end


end
