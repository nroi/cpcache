defmodule Cpc.Downloader do
  alias Cpc.Downloader, as: Dload
  require Logger
  use GenServer
  defstruct mirror: nil,
            sock: nil,
            cache_directory: nil,
            serializer: nil,
            action: nil

  def start_link(mirror_url, serializer, sock, cache_directory) do
    GenServer.start_link(__MODULE__, %Dload{sock: sock,
                                            mirror: mirror_url,
                                            cache_directory: cache_directory,
                                            serializer: serializer,
                                            action: {:recv_header, %{uri: nil, range_start: nil}}})
  end


  # TODO we still have two downloads if one client downloads the file from start, the other client
  # is using content ranges.

  defp get_filename(uri, mirror, cache_dir) do
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

  defp setup_port(filename) do
    cmd = "/usr/bin/inotifywait"
    args = ["-q", "--format", "%e", "--monitor", "-e", "modify", filename]
    _ = Port.open({:spawn_executable, cmd}, [{:args, args}, :stream, :binary, :exit_status,
                                           :hide, :use_stdio, :stderr_to_stdout])
    Logger.debug "Port started."
  end

  defp serve_via_http(filename, state, hs) do
    _ = Logger.info "Serve file #{filename} via HTTP."
    url = state.mirror |> String.replace_suffix("/", "") |> Path.join(hs.uri)
    headers = case hs.range_start do
      nil ->
        []
      rs -> [{"Range", "bytes=#{rs}-"}]
    end
    {:ok, _} = :hackney.request(:get, url, headers, "", [:async])
    case content_length_from_mailbox() do
      {:ok, {_, full_content_length}} ->
        reply_header = header(full_content_length, hs.range_start)
        send state.serializer, {self(), :content_length, {filename, full_content_length}}
        :ok = :gen_tcp.send(state.sock, reply_header)
        _ = Logger.debug "Sent header: #{reply_header}"
        file = File.open!(filename, [:write])
        {:noreply, %{state | action: {:download, state.sock, {file, filename}}}}
      {:error, :not_found} ->
        send state.serializer, {self(), :not_found}
        reply_header = header_404()
        :ok = :gen_tcp.send(state.sock, reply_header)
        case :gen_tcp.close(state.sock) do
          :ok -> :ok
          {:error, :closed} -> :ok
        end
        {:stop, :normal, nil}
    end
  end

  defp serve_via_redirect(db_url, sock) do
    _ = Logger.debug "Serve database file via http redirect"
    :ok = :gen_tcp.send(sock, header_301(db_url))
    :ok = :gen_tcp.close(sock)
    {:noreply, :sock_closed}
  end

  defp serve_via_cache(filename, sock, range_start) do
    _ = Logger.info "Serve file #{filename} from cache."
    content_length = File.stat!(filename).size
    reply_header = header(content_length, range_start)
    :ok = :gen_tcp.send(sock, reply_header)
    case range_start do
      nil ->
        {:ok, ^content_length} = :file.sendfile(filename, sock)
      rs ->
        Logger.debug "Send partial file, from #{rs} until end."
        f = File.open!(filename, [:read, :raw])
        {:ok, _} = :file.sendfile(f, sock, range_start, content_length - rs, [])
        :ok = File.close(f)
    end
    _ = Logger.debug "Download from cache complete."
    :ok = :gen_tcp.close(sock)
    {:stop, :normal, nil}
  end

  defp serve_via_growing_file(filename, state, range_start, full_content_length) do
    setup_port(filename)
    Logger.info "File #{filename} is already being downloaded, initiate download from " <>
                "growing file."
    reply_header = header(full_content_length, range_start)
    :ok = :gen_tcp.send(state.sock, reply_header)
    file = File.open!(filename, [:read, :raw])
    {:noreply, %{state | action: {:inotify, {file, filename}, full_content_length, 0}}}
  end

  defp serve_via_cache_http(state, filename, hs) do
    # A partial file already exists on the filesystem, but this file was saved in a previous
    # download process that did not finish -- the file is not in the process of being downloaded.
    # We serve the beginning of the file from the cache, if possible. If the requester requested a
    # range that exceeds the amount of bytes we have saved for this file, everything is downloaded
    # via HTTP.
    send state.serializer, {self(), :state?, filename}
    receive do
      {:downloading, full_content_length} ->
        serve_via_growing_file(filename, state, hs.range_start, full_content_length)
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
          {:http, from} -> {from, fn -> :ok end}
        end
        headers = [{"Range", "bytes=#{start_http_from_byte}-"}]
        url = Path.join(state.mirror, hs.uri)
        {:ok, _} = :hackney.request(:get, url, headers, "", [:async])
        case content_length_from_mailbox() do
          {:ok, {_, full_content_length}} ->
            file = File.open!(filename, [:append])
            send state.serializer, {self(), :content_length, {filename, full_content_length}}
            reply_header = header(full_content_length, hs.range_start)
            :ok = :gen_tcp.send(state.sock, reply_header)
            _ = Logger.debug "Sent header: #{reply_header}"
            send_from_cache.()
            :ok = File.close(raw_file)
            {:noreply, %{state | action: {:download, state.sock, {file, filename}}}}
          {:error, :not_found} ->
            send state.serializer, {self(), :not_found}
            reply_header = header_404()
            :ok = :gen_tcp.send(state.sock, reply_header)
            _ = Logger.debug "Sent header: #{reply_header}"
            case :gen_tcp.close(state.sock) do
              :ok -> :ok
              {:error, :closed} -> :ok
            end
            {:stop, :normal, nil}
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
    case get_filename(hs.uri, state.mirror, state.cache_directory) do
      {:database, db_url} ->
        serve_via_redirect(db_url, state.sock)
      {:complete_file, filename} ->
        serve_via_cache(filename, state.sock, hs.range_start)
      {:partial_file, filename} ->
        serve_via_cache_http(state, filename, hs)
      {:not_found, filename} ->
        send state.serializer, {self(), :state?, filename}
        receive do
          {:downloading, content_length} ->
            serve_via_growing_file(filename, state, hs.range_start, content_length)
          :unknown ->
            serve_via_http(filename, state, hs)
        end
    end
  end

  def handle_info({:hackney_response, _, :done},
                  state = %Dload{action: {:download, sock, {f, n}}}) do
    :ok = File.close(f)
    basename = Path.basename(n)
    dirname = Path.dirname(n)
    prev_dir = System.cwd
    download_dir_basename = n |> Path.dirname |> Path.basename
    :ok = :file.set_cwd(Path.join(dirname, ".."))
    :ok = File.ln_s(Path.join(download_dir_basename, basename), basename)
    :ok = :file.set_cwd(prev_dir)
    _ = Logger.debug "Closing file and socket."
    :ok = :gen_tcp.close(sock)
    :ok = GenServer.cast(state.serializer, {:download_completed, n})
    {:noreply, :sock_closed}
  end

  def handle_info({:hackney_response, _, bin}, state = %Dload{action: {:download, sock, {f, n}}}) do
    :ok = IO.binwrite(f, bin)
    case :gen_tcp.send(sock, bin) do
      :ok ->
        {:noreply, state}
      {:error, :closed} ->
        Logger.info "Connection closed by client during data transfer. File #{n} is incomplete."
        :ok = File.close(f)
        :ok = GenServer.cast(state.serializer, {:download_completed, n})
        {:noreply, :sock_closed}
    end
  end

  def handle_info({:tcp_closed, _}, state = %Dload{action: {:download, _, {_,n}}}) do
    Logger.info "Connection closed by client during data transfer. File #{n} is incomplete."
    :ok = GenServer.cast(state.serializer, {:download_completed, n})
    {:stop, :normal, nil}
  end

  def handle_info({:tcp_closed, _}, state = %Dload{action: {:inotify, {_, n}, _, _}}) do
    Logger.info "Connection closed by client during data transfer. File #{n} is incomplete."
    :ok = GenServer.cast(state.serializer, {:download_completed, n})
    {:stop, :normal, nil}
  end

  def handle_info({port, {:data, "MODIFY\n" <> _}, },
                  state = %Dload{action: {:inotify, {f, n}, content_length, size}}) do
    new_size = File.stat!(n).size
    case new_size do
      ^content_length ->
        Logger.debug "Download from growing file complete."
        {:ok, _} = :file.sendfile(f, state.sock, size, new_size - size, [])
        Port.close(port)
        :ok = File.close(f)
        :ok = :gen_tcp.close(state.sock)
        {:noreply, :sock_closed}
      ^size ->
        # received MODIFY although size is unchanged -- probably because something was written to
        # the file after the previous MODIFY event and before we have called File.stat.
        {:noreply, state}
      _ ->
        true = new_size < content_length
        {:ok, _} = :file.sendfile(f, state.sock, size, new_size - size, [])
        {:noreply, %{state | action: {:inotify, {f, n}, content_length, new_size}}}
    end
  end

  def handle_info({:http, _sock, http_packet}, state) do
    Logger.debug "ignored: #{inspect http_packet}"
    {:noreply, state}
  end

  def handle_info({:tcp_closed, _}, :sock_closed) do
    Logger.info "Connection closed."
    {:stop, :normal, nil}
  end

  defp content_length_from_mailbox() do
    partial_or_complete = receive do
      {:hackney_response, _, {:status, 200, _}} ->
        Logger.debug "Received 200, download entire file via HTTP."
        {:ok, :complete}
      {:hackney_response, _, {:status, 206, _}} ->
        Logger.debug "Received 206, download partial file via HTTP."
        {:ok, :partial}
      {:hackney_response, _, {:status, 404, _}} ->
        Logger.warn "Mirror returned 404."
        {:error, :not_found}
      {:hackney_response, _, {:status, num, msg}} ->
        raise "Expected HTTP response 200, got instead: #{num} (#{msg})"
    after 1000 ->
        raise "Timeout while waiting for response to GET request."
    end
    with {:ok, status} <- partial_or_complete do
      header = receive do
        {:hackney_response, _, {:headers, proplist}} ->
          proplist |> Enum.map(fn {key, val} -> {String.downcase(key), String.downcase(val)} end)
      after 1000 ->
          raise "Timeout while waiting for response to GET request."
      end
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

end
