defmodule Cpc.Downloader do
  require Logger
  use GenServer

  def start_link([sock], []) do
    GenServer.start_link(__MODULE__, sock)
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
    file_exists = Enum.member?(File.ls!(dirname), basename)
    is_database = String.ends_with?(basename, ".db")
    case {is_database, file_exists} do
      {true, _} ->
        {:database, Path.join(http_source, uri)}
      {false, false} ->
        {:not_found, Path.join([dirname, "downloads", basename])}
      {false, true} ->
        {:file, filename}
    end
  end

  def get_url() do
    Application.get_env(:cpc, :mirror) |> String.replace_suffix("/", "")
  end

  defp header(content_length) do
    date = to_string(:httpd_util.rfc1123_date)
    "HTTP/1.1 200 OK\r\n" <>
    "Server: http-relay\r\n" <>
    "Date: #{date}\r\n" <>
    "Content-Type: application/octet-stream\r\n" <>
    "Content-Length: #{content_length}\r\n\r\n"
  end

  def header_301(location) do
    date = to_string(:httpd_util.rfc1123_date)
    "HTTP/1.1 301 Moved Permanently\r\n" <>
    "Server: http-relay\r\n" <>
    "Date: #{date}\r\n" <>
    "Content-Type: text/html\r\n" <>
    "Content-Length: 0\r\n" <>
    "Location: #{location}\r\n\r\n"
  end

  def content_length_from_header(header_proplist) do
    header_proplist |> Enum.find_value(fn {key, value} ->
      case String.downcase(key) do
        "content-length" -> value
        _ -> false
      end
    end) |> String.to_integer
  end

  defp setup_port(filename) do
    cmd = "/usr/bin/inotifywait"
    args = ["-q", "--format", "%e", "--monitor", "-e", "modify", filename]
    Logger.warn "attempt to start port"
    _ = Port.open({:spawn_executable, cmd}, [{:args, args}, :stream, :binary, :exit_status,
                                           :hide, :use_stdio, :stderr_to_stdout])
    Logger.warn "port started"
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



  def handle_info({:http, {_, :stream, bin}}, state = {:download, sock, {f, _}}) do
    :ok = :gen_tcp.send(sock, bin)
    :ok = IO.binwrite(f, bin)
    {:noreply, state}
  end

  def handle_info({:http, {_, :stream_end, _}}, {:download, sock, {f, n}}) do
    :ok = File.close(f)
    basename = Path.basename(n)
    dirname = Path.dirname(n)
    prev_dir = System.cwd
    download_dir_basename = n |> Path.dirname |> Path.basename
    :ok = :file.set_cwd(Path.join(dirname, ".."))
    :ok = File.ln_s(Path.join(download_dir_basename, basename), basename)
    :ok = :file.set_cwd(prev_dir)
    _ = Logger.info "Closing file and socket."
    :ok = :gen_tcp.close(sock)
    :ok = GenServer.cast(Cpc.Serializer, {:download_completed, n})
    {:noreply, :sock_closed}
  end

  def handle_info({:tcp, _, msg = "GET /" <> rest}, sock) when is_port(sock) do
    _ = Logger.debug "Incoming get request: #{msg}"
    uri = case String.split(rest) do
      [uri, _] -> URI.decode(uri)
    end
    _ = Logger.info "Process request for filename #{uri}"
    case get_filename(uri) do
      {:database, db_url} ->
        Logger.debug "Serve database file via http redirect"
        :ok = :gen_tcp.send(sock, header_301(db_url))
        :ok = :gen_tcp.close(sock)
        {:noreply, :sock_closed}
      {:file, filename} ->
        _ = Logger.info "Serve file #{filename} from cache."
        content_length = File.stat!(filename).size
        reply_header = header(content_length)
        :ok = :gen_tcp.send(sock, reply_header)
        {:ok, ^content_length} = :file.sendfile(filename, sock)
        _ = Logger.debug "Download from cache complete."
        :ok = :gen_tcp.close(sock)
        {:stop, :normal, nil}
      {:not_found, filename} ->
        send Cpc.Serializer, {self(), :state?, filename}
        Logger.debug "send :state? from #{inspect self()}"
        receive do
          {:downloading, content_length} ->
            setup_port(filename)
            Logger.info "File #{filename} is already being downloaded, initiate download from " <>
                        "growing file."
            reply_header = header(content_length)
            :ok = :gen_tcp.send(sock, reply_header)
            file = File.open!(filename, [:read, :raw])
            {:noreply, {:tail, sock, {file, filename}, content_length, 0}}
          :unknown ->
            _ = Logger.info "serve file #{filename} via HTTP."
            url = Path.join(get_url(), uri)
            _ = Logger.warn "URL is #{inspect url}"
            {:ok, _} = :httpc.request(:get, {to_charlist(url), []}, [], sync: false, stream: :self)
            content_length = content_length_from_mailbox()
            _ = Logger.info "content length: #{content_length}"
            reply_header = header(content_length)
            send Cpc.Serializer, {self(), :content_length, {filename, content_length}}
            :ok = :gen_tcp.send(sock, reply_header)
            _ = Logger.info "sent header: #{reply_header}"
            file = File.open!(filename, [:write])
            {:noreply, {:download, sock, {file, filename}}}
        end
    end
  end

  def handle_info({:tcp, _, "Host: " <> _}, sock) do
    {:noreply, sock}
  end
  def handle_info({:tcp, _, "User-Agent: " <> _}, sock) do
    {:noreply, sock}
  end
  def handle_info({:tcp, _, "Accept: " <> _}, sock) do
    {:noreply, sock}
  end
  def handle_info({:tcp, _, "If-Modified-Since: " <> _}, sock) do
    {:noreply, sock}
  end
  def handle_info({:tcp, _, "\r\n"}, sock) do
    {:noreply, sock}
  end
  def handle_info({:tcp, _, msg}, sock) do
    Logger.warn "ignore header field: #{msg}"
    {:noreply, sock}
  end

  def handle_info({:tcp_closed, _}, :sock_closed) do
    Logger.info "connection closed."
    {:stop, :normal, nil}
  end

  defp content_length_from_mailbox() do
    receive do
      {:http, {_, :stream_start, header}} ->
        _ = Logger.info "header is: #{inspect header}"
        header = header |> Enum.map(fn {key, val} -> {to_string(key), to_string(val)} end)
        content_length_from_header(header)
      after 1000 ->
          raise "Timeout while waiting for response to GET request."
    end
  end

end
