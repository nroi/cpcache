defmodule Cpc.Downloader do
  require Logger
  use GenServer

  def header_404() do
    date = to_string(:httpd_util.rfc1123_date)
    "HTTP/1.1 404 Not Found\r\n" <>
    "Server: cpc\r\n" <>
    "Date: #{date}\r\n" <>
    "Content-Length: 0\r\n" <>
    "\r\n"
  end

  def start_link([sock], []) do
    GenServer.start_link(__MODULE__, {sock, :recv_header, %{uri: nil, range_start: nil}})
  end

  # returns {:exists, filename} if it exists, else {:not_found, filename}
  # when {:not_found, filename} is returned, filename is the file where the file is meant to be
  # stored in before symlinking.
  defp get_filename(uri) do
    cache_dir = Application.get_env(:cpc, :cache_directory)
    http_source = get_url()
    filename = Path.join(cache_dir, uri)
    dirname = Path.dirname(filename)
    basename = Path.basename(filename)
    complete_file_exists = Enum.member?(File.ls!(dirname), basename)
    partial_file_exists = Enum.member?(File.ls!(Path.join(dirname, "downloads")), basename)
    is_database = String.ends_with?(basename, ".db")
    case {is_database, complete_file_exists, partial_file_exists} do
      {true, _, _} ->
        {:database, Path.join(http_source, uri)}
      {false, false, false} ->
        {:not_found, Path.join([dirname, "downloads", basename])}
      {false, true, _} ->
        {:complete_file, filename}
      {false, false, true} ->
        {:partial_file, Path.join([dirname, "downloads", basename])}
    end
  end

  def get_url() do
    Application.get_env(:cpc, :mirror) |> String.replace_suffix("/", "")
  end

  defp header(content_length, full_content_length, range_start \\ nil) do
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
    "Server: http-relay\r\n" <>
    "Date: #{date}\r\n" <>
    "Content-Type: text/html\r\n" <>
    "Content-Length: 0\r\n" <>
    "Location: #{location}\r\n\r\n"
  end

  defp setup_port(filename) do
    cmd = "/usr/bin/inotifywait"
    args = ["-q", "--format", "%e", "--monitor", "-e", "modify", filename]
    _ = Port.open({:spawn_executable, cmd}, [{:args, args}, :stream, :binary, :exit_status,
                                           :hide, :use_stdio, :stderr_to_stdout])
    Logger.warn "Port started."
  end

  def handle_info({:http, _, {:http_request, :GET, {:abs_path, path}, _}}, {sock, :recv_header, hs}) do
    uri = case path do
      "/" <> rest -> URI.decode(rest)
    end
    {:noreply, {sock, :recv_header, %{hs | uri: uri}}}
  end

  def handle_info({:http, _, {:http_header, _, :Range, _, range}}, {sock, :recv_header, hs}) do
    range_start = case range do
      "bytes=" <> rest ->
        {start, "-"} = Integer.parse(rest)
        start
    end
    {:noreply, {sock, :recv_header, %{hs | range_start: range_start}}}
  end

  def handle_info({:http, _, :http_eoh}, {sock, :recv_header, hs}) do
    case get_filename(hs.uri) do
      {:database, db_url} ->
        Logger.debug "Serve database file via http redirect"
        :ok = :gen_tcp.send(sock, header_301(db_url))
        :ok = :gen_tcp.close(sock)
        {:noreply, :sock_closed}
      {:complete_file, filename} ->
        _ = Logger.info "Serve file #{filename} from cache."
        content_length = File.stat!(filename).size
        reply_header = header(content_length, content_length, hs.range_start)
        :ok = :gen_tcp.send(sock, reply_header)
        case hs.range_start do
          nil ->
            {:ok, ^content_length} = :file.sendfile(filename, sock)
          rs ->
            Logger.debug "send partial file, from #{rs} until end."
            f = File.open!(filename, [:read, :raw])
            {:ok, _} = :file.sendfile(f, sock, hs.range_start, content_length - rs, [])
            :ok = File.close(f)
        end
        _ = Logger.debug "Download from cache complete."
        :ok = :gen_tcp.close(sock)
        {:stop, :normal, nil}
      {:partial_file, filename} ->
        _ = Logger.info "Serve file #{filename} from cache and/or http"
        # TODO just like with :not_found, we should inform the serializer that we are going to
        # download the file.
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
        {start_http_from_byte, send_from_cache, bytes_via_cache} = case retrieval_start_method do
          {:file, from} ->
            send_ = fn ->
              {:ok, _} = :file.sendfile(raw_file, sock, from, filesize - from, [])
            end
            {filesize, send_, filesize - from}
          {:http, from} -> {from, fn -> :ok end, 0}
        end
        headers = [{"Range", "bytes=#{start_http_from_byte}-"}]
        url = Path.join(get_url(), hs.uri)
        {:ok, _} = :hackney.request(:get, url, headers, "", [:async])
        {content_length, full_content_length} = content_length_from_mailbox()
        actual_content_length = content_length + bytes_via_cache
        reply_header = header(actual_content_length, full_content_length, hs.range_start)
        :ok = :gen_tcp.send(sock, reply_header)
        _ = Logger.debug "sent header: #{reply_header}"
        send_from_cache.()
        :ok = File.close(raw_file)
        file = File.open!(filename, [:append])
        {:noreply, {:download, sock, {file, filename}}}
      {:not_found, filename} ->
        send Cpc.Serializer, {self(), :state?, filename}
        receive do
          {:downloading, content_length} ->
            setup_port(filename)
            Logger.info "File #{filename} is already being downloaded, initiate download from " <>
                        "growing file."
            reply_header = header(content_length, hs.range_start)
            :ok = :gen_tcp.send(sock, reply_header)
            file = File.open!(filename, [:read, :raw])
            {:noreply, {:tail, sock, {file, filename}, content_length, 0}}
          :unknown ->
            _ = Logger.info "Serve file #{filename} via HTTP."
            url = Path.join(get_url(), hs.uri)
            headers = case hs.range_start do
              nil ->
                []
              rs -> [{"Range", "bytes=#{rs}-"}]
            end
            {:ok, _} = :hackney.request(:get, url, headers, "", [:async])
            case content_length_from_mailbox() do
              {:ok, {content_length, full_content_length}} ->
                reply_header = header(content_length, full_content_length, hs.range_start)
                send Cpc.Serializer, {self(), :content_length, {filename, content_length}}
                :ok = :gen_tcp.send(sock, reply_header)
                _ = Logger.debug "sent header: #{reply_header}"
                file = File.open!(filename, [:write])
                {:noreply, {:download, sock, {file, filename}}}
              {:error, :not_found} ->
                send Cpc.Serializer, {self(), :not_found}
                reply_header = header_404()
                :ok = :gen_tcp.send(sock, reply_header)
                case :gen_tcp.close(sock) do
                  :ok -> :ok
                  {:error, :closed} -> :ok
                end
                {:stop, :normal, nil}
            end
        end
    end
  end

  def handle_info({:hackney_response, _, :done}, {:download, sock, {f, n}}) do
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
    :ok = GenServer.cast(Cpc.Serializer, {:download_completed, n})
    {:noreply, :sock_closed}
  end

  def handle_info({:hackney_response, _, bin}, state = {:download, sock, {f, n}}) do
    :ok = IO.binwrite(f, bin)
    case :gen_tcp.send(sock, bin) do
      :ok ->
        {:noreply, state}
      {:error, :closed} ->
        Logger.info "Connection closed by client during data transfer. File #{n} is incomplete."
        :ok = File.close(f)
        :ok = GenServer.cast(Cpc.Serializer, {:download_completed, n})
        {:noreply, :sock_closed}
    end
  end

  def handle_info({:tcp_closed, _}, {:download, _, {_,n}}) do
    Logger.info "Connection closed by client during data transfer. File #{n} is incomplete."
    :ok = GenServer.cast(Cpc.Serializer, {:download_completed, n})
    {:stop, :normal, nil}
  end

  def handle_info({port, {:data, "MODIFY\n" <> _}, },
                  state = {:tail, sock, {f, n}, content_length, size}) do
    new_size = File.stat!(n).size
    case new_size do
      ^content_length ->
        Logger.debug "Download from growing file complete."
        {:ok, _} = :file.sendfile(f, sock, size, new_size - size, [])
        Port.close(port)
        :ok = File.close(f)
        :ok = :gen_tcp.close(sock)
        {:noreply, :sock_closed}
      ^size ->
        # received MODIFY although size is unchanged -- probably because something was written to
        # the file after the previous MODIFY event and before we have called File.stat.
        {:noreply, state}
      _ ->
        true = new_size < content_length
        {:ok, _} = :file.sendfile(f, sock, size, new_size - size, [])
        {:noreply, {:tail, sock, {f, n}, content_length, new_size}}
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
