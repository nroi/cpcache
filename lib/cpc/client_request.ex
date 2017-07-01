defmodule Cpc.ClientRequest do
  @max_body_size 500000
  alias Cpc.ClientRequest, as: CR
  alias Cpc.Filewatcher
  alias Cpc.Utils
  require Logger
  use GenServer
  defstruct sock: nil,
            distro: nil, # either :x86 or :arm
            serializer: nil,
            sent_header: false, # true if we replied by sending the header to the client
            action: nil,
            timer_ref: nil,
            header_fields: [], # the unchanged headers, the way we received them
            headers: %{}, # a map containing the relevant data extracted from above headers
            request: nil # GET or POST



  def start_link(distro, sock) do
    GenServer.start_link(__MODULE__, init_state(distro, sock))
  end

  defp init_state(distro, sock) do
    serializer = case distro do
      :x86 -> :x86_serializer
      :arm -> :arm_serializer
    end
    %CR{sock: sock,
        distro: distro,
        serializer: serializer,
        sent_header: false,
        action: :recv_header}
  end

  def init(state) do
    Process.flag(:trap_exit, true)
    {:ok, state}
  end

  defp get_filename(uri, distro) do
    cache_dir = case :ets.lookup(:cpc_config, :cache_directory) do
                  [{:cache_directory, cd}] -> Path.join(cd, to_string distro)
                end
    [{^distro, %{mirrors: [mirror | _]}}] = :ets.lookup(:cpc_config, distro)
    filename = Path.join(cache_dir, uri)
    dirname = Path.dirname(filename)
    basename = Path.basename(filename)
    is_database = String.ends_with?(basename, ".db")
    {partial_file_exists, complete_file_exists} = case is_database do
      true -> {false, false}
      false ->
        case File.stat(Path.join(dirname, basename)) do
          {:error, :enoent} -> {false, false}
          {:ok, %File.Stat{size: 0}} -> {false, false}
          {:ok, %File.Stat{size: size}} ->
            case content_length(uri, distro) do
              {:ok, ^size} ->             {true, true}
              {:ok, cl} when cl > size -> {true, false}
              {:error, :not_found} ->
                # The file exists, but we cannot retrieve its content length: This can happen if
                # the remote server doesn't have this file anymore (i.e., the file is outdated)
                # and its content-length is not saved in the database for some reason.
                # In this case, we want to reply 404, rather than sending a
                # possibly incomplete file.
                {false, false}
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

  defp key_from_config() do
    case :ets.lookup(:cpc_config, :recv_packages) do
      [recv_packages: %{key: sk}] -> {:ok, sk}
      _ -> {:error, :key_not_found}
    end
  end

  defp validate_timestamp(timestamp) do
    current_time = case :erlang.timestamp() do
                     {megasecs, secs, _} -> megasecs * 1000000 + secs
                   end
    if current_time - timestamp < 60 do
      :ok
    else
      {:error, :timestamp_expired}
    end
  end

  defp validate_hmac(content, hmac, key, timestamp) do
    to_hash = content <> to_string(timestamp) <> "\n"
    our_hmac = Base.encode16(:crypto.hmac(:sha256, key, to_hash))
    if String.downcase(hmac) == String.downcase(our_hmac) do
      :ok
    else
      {:error, :invalid_hmac}
    end
  end

  def authorize(_auth = {hmac, timestamp}, content) do
    with :ok <- validate_timestamp(timestamp),
        {:ok, key} <- key_from_config(),
         :ok <- validate_hmac(content, hmac, key, timestamp),
      do: {:ok, content}
  end

  defp extract_headers(headers) do
    init_map = %{continue: false, range_start: nil}
    Enum.reduce(headers, init_map, fn
      ({:http_header, _, :"Content-Length", _, value}, acc) ->
        Map.put(acc, :content_length, String.to_integer(value))
      ({:http_header, _, "Expect", _, "100-continue"}, acc) ->
        Map.put(acc, :continue, true)
      ({:http_header, _, "Timestamp", _, timestamp}, acc) ->
        Map.put(acc, :timestamp, String.to_integer(timestamp))
      ({:http_header, _, :Authorization, _, hmac}, acc) ->
        Map.put(acc, :hmac, hmac)
      ({:http_header, _, :Range, _, range}, acc) ->
        Map.put(acc, :range_start, case range do
                                     "bytes=" <> rest ->
                                       {start, "-"} = Integer.parse(rest)
                                       start
                                   end)
      (m, acc) ->
        _ = Logger.debug "Ignored: #{inspect m}"
        acc
    end)
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
        "Content-Range: bytes #{rs}-#{range_end}/#{full_content_length}\r\n"
    end
    date = to_string(:httpd_util.rfc1123_date)
    "HTTP/1.1 200 OK\r\n" <>
    "Server: cpcache\r\n" <>
    "Date: #{date}\r\n" <>
    "Content-Type: application/octet-stream\r\n" <>
    "Content-Length: #{content_length}\r\n" <>
    content_range_line <>
    "\r\n"
  end

  defp default_header(text, content_length) do
    date = to_string(:httpd_util.rfc1123_date)
    "HTTP/1.1 #{text}\r\n" <>
    "Server: cpcache\r\n" <>
    "Date: #{date}\r\n" <>
    "Content-Length: #{content_length}\r\n" <>
    "\r\n"
  end

  defp header_from_code(code, content_length \\ 0)
  defp header_from_code(100, cl), do: default_header("100 Continue", cl)
  defp header_from_code(200, cl), do: default_header("200 OK", cl)
  defp header_from_code(403, cl), do: default_header("403 Forbidden", cl)
  defp header_from_code(404, cl), do: default_header("404 Not Found", cl)
  defp header_from_code(413, cl), do: default_header("413 Payload Too Large", cl)
  defp header_from_code(500, cl), do: default_header("500 Internal Server Error", cl)

  defp header_301(location) do
    date = to_string(:httpd_util.rfc1123_date)
    "HTTP/1.1 301 Moved Permanently\r\n" <>
    "Server: cpcache\r\n" <>
    "Date: #{date}\r\n" <>
    "Content-Length: 0\r\n" <>
    "Location: #{location}\r\n" <>
    "\r\n"
  end

  # Given the URI requested by the user, returns the URI we need to send our HTTP request to
  def mirror_uri(uri, distro, round_robin) do
    mirror = random_mirror(distro, round_robin)
    mirror |> String.replace_suffix("/", "") |> Path.join(uri)
  end

  # Returns the mirror for the given distro. round_robin should be set to true if
  # a new mirror should be chosen afterwards.
  def random_mirror(distro, round_robin) when distro == :x86 or distro == :arm do
    index = case {round_robin, :ets.lookup(:cpc_round_robin, distro)} do
              {true, [{^distro, {index, num_mirrors}}]} ->
                new_idx = rem(index + 1, num_mirrors)
                Logger.warn "insert new index: #{inspect new_idx}"
                :ets.insert(:cpc_round_robin, {distro, {new_idx, num_mirrors}})
                index
              {false, [{^distro, {index, _}}]} -> index
            end
    case :ets.lookup(:cpc_config, distro) do
      [{_, %{mirrors: mirrors}}] ->
        :ets.lookup(:cpc_config, distro)
        Enum.at(mirrors, index)
    end
  end

  # Given the requested URI, fetch the full content-length from the server.
  # req_uri must be the URI as requested by the user, not the URI that will be used to GET the file
  # via HTTP.
  def content_length(req_uri, distro) do
    db_result = :mnesia.transaction(fn ->
      :mnesia.read({ContentLength, {distro, Path.basename(req_uri)}})
    end)
    result = case db_result do
      {:atomic, [{ContentLength, {^distro, _basename}, content_length}]} -> {:ok, content_length}
      {:atomic, []} -> :not_found
    end
    case result do
      {:ok, content_length} ->
        _ = Logger.debug "Retrieve content-length for #{req_uri} from cache."
        {:ok, content_length}
      :not_found ->
        _ = Logger.debug "Retrieve content-length for #{req_uri} via HTTP HEAD request."
        uri = mirror_uri(req_uri, distro, false)
        headers = case :httpc.request(:head, {to_charlist(uri), []},[],[]) do
                    {:ok, {{_, 200, _}, headers, _}} -> {:ok, Utils.headers_to_lower(headers)}
                    {:ok, {{_, 404, _}, _headers, _}} -> {:error, :not_found}
        end
        with {:ok, headers} <- headers do
          content_length = :proplists.get_value("content-length", headers) |> String.to_integer
          {:atomic, :ok} = :mnesia.transaction(fn ->
            :mnesia.write({ContentLength, req_uri, content_length})
          end)
          _ = Logger.debug "Saved to database: content-length #{content_length} for #{req_uri}"
          {:ok, content_length}
        end
    end
  end

  defp serve_via_http(filename, state, uri) do
    _ = Logger.info "Serve file #{filename} via HTTP."
    url = mirror_uri(uri, state.distro, true)
    Cpc.Downloader.start_link(url, filename, self(), state.distro, 0)
    receive do
      {:content_length, content_length} ->
        reply_header = header(content_length, state.headers.range_start)
        :ok = :gen_tcp.send(state.sock, reply_header)
        _ = Logger.debug "Sent header: #{reply_header}"
        file = File.open!(filename, [:read, :raw])
        start_size = case state.headers.range_start do
          nil -> 0
          rs  -> rs
        end
        {:ok, _} = Filewatcher.start_link(self(), filename, content_length, start_size)
        action = {:filewatch, {file, filename}, content_length, 0}
        {:noreply, %{state | sent_header: true, action: action}}
      :not_found ->
        _ = Logger.debug "Remove file #{filename}."
        # The empty file was previously created by Cpc.Serializer.
        :ok = File.rm(filename)
        reply_header = header_from_code(404)
        :ok = :gen_tcp.send(state.sock, reply_header)
        {:noreply, %{state | sent_header: true, action: :recv_header}}
    end
  end

  defp serve_package_via_redirect(state, uri) do
    url = mirror_uri(uri, state.distro, true)
    _ = Logger.info "Serve package via HTTP redirect from #{url}."
    :ok = :gen_tcp.send(state.sock, header_301(url))
    {:noreply, %{state | sent_header: true, action: :recv_header}}
  end

  defp serve_db_via_redirect(db_url, state) do
    _ = Logger.info "Serve database file #{db_url} via HTTP redirect."
    :ok = :gen_tcp.send(state.sock, header_301(db_url))
    {:noreply, %{state | sent_header: true, action: :recv_header}}
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
        _ = Logger.warn "File is already fully retrieved by the client."
        :ok
      rs when rs < content_length ->
        _ = Logger.debug "Send partial file, from #{rs} until end."
        f = File.open!(filename, [:read, :raw])
        {:ok, _} = :file.sendfile(f, state.sock, range_start, content_length - rs, [])
        :ok = File.close(f)
    end
    _ = Logger.debug "Download from cache complete."
    {:noreply, %{state | sent_header: true, action: :recv_header}}
  end

  defp serve_via_growing_file(filename, state) do
    %CR{request: {:GET, uri}} = state
    {:ok, full_content_length} = content_length(uri, state.distro)
    {:ok, _} = Filewatcher.start_link(self(), filename, full_content_length)
    _ = Logger.info "File #{filename} is already being downloaded, initiate download from " <>
                "growing file."
    reply_header = header(full_content_length, state.headers.range_start)
    :ok = :gen_tcp.send(state.sock, reply_header)
    file = File.open!(filename, [:read, :raw])
    action = {:filewatch, {file, filename}, full_content_length, 0}
    {:noreply, %{state | sent_header: true, action: action}}
  end

  defp serve_via_cache_and_http(state, filename, uri) do
    # A partial file already exists on the filesystem, but this file was saved in a previous
    # download process that did not finish -- the file is not in the process of being downloaded.
    # We serve the beginning of the file from the cache, if possible. If the requester requested a
    # range that exceeds the amount of bytes we have saved for this file, everything is downloaded
    # via HTTP.
    filesize = File.stat!(filename).size
    retrieval_start_method = case state.headers.range_start do
      nil -> {:file, 0} # send file starting from 0th byte.
      rs  ->
        cond do
          rs <  filesize -> {:file, state.headers.range_start}
          rs >= filesize -> {:http, state.headers.range_start}
        end
    end
    _ = Logger.debug "Start of requested content-range: #{inspect state.headers.range_start}"
    {start_http_from_byte, send_from_cache} = case retrieval_start_method do
      {:file, from} ->
        send_ = fn ->
          _ = Logger.debug "Sending #{filesize - from} bytes from cached file."
          File.open(filename, [:read, :raw], fn raw_file ->
            {:ok, _} = :file.sendfile(raw_file, state.sock, from, filesize - from, [])
          end)
        end
        {filesize, send_}
      {:http, from} ->
        {from, fn -> :ok end}
    end
    _ = Logger.debug "Start HTTP download from byte #{start_http_from_byte}"
    range_start = state.headers.range_start
    case content_length(uri, state.distro) do
      {:ok, cl} when cl == filesize ->
        _ = Logger.warn "The entire file has already been downloaded by the server."
        serve_via_cache(filename, state, range_start)
      {:ok, cl} when cl == range_start ->
        # The client requested a content range, although he already has the entire file.
        reply_header = header(cl, range_start)
        :ok = :gen_tcp.send(state.sock, reply_header)
        _ = Logger.debug "Sent header: #{reply_header}"
        _ = Logger.warn "File is already fully retrieved by the client."
        {:noreply, %{state | sent_header: true, action: :recv_header}}
      {:ok, _ }->
        url = mirror_uri(uri, state.distro, true)
        Cpc.Downloader.start_link(url, filename, self(), state.distro, start_http_from_byte)
        receive do
          {:content_length, content_length} ->
            file = File.open!(filename, [:read, :raw])
            reply_header = header(content_length, range_start)
            :ok = :gen_tcp.send(state.sock, reply_header)
            _ = Logger.debug "Sent header: #{reply_header}"
            send_from_cache.()
            {:ok, _} = Filewatcher.start_link(self(),
                                              filename,
                                              content_length,
                                              start_http_from_byte)
            action = {:filewatch, {file, filename}, content_length, start_http_from_byte}
            {:noreply, %{state | sent_header: true, action: action}}
          :not_found ->
            reply_header = header_from_code(404)
            :ok = :gen_tcp.send(state.sock, reply_header)
            _ = Logger.debug "Sent header: #{reply_header}"
            {:noreply, %{state | sent_header: true, action: :recv_header}}
        end
      {:error, :not_found} ->
        reply_header = header_from_code(404)
        :ok = :gen_tcp.send(state.sock, reply_header)
        _ = Logger.debug "Sent header: #{reply_header}"
        {:noreply, %{state | sent_header: true, action: :recv_header}}
    end
  end

  defp serve_via_partial_file(state, filename, uri) do
    # The requested file already exists, but its size is smaller than the content length
    send state.serializer, {self(), :state?, filename}
    receive do
      :downloading ->
        serve_via_growing_file(filename, state)
      :unknown ->
        _ = Logger.info "Serve file #{filename} partly via cache, partly via HTTP."
        serve_via_cache_and_http(state, filename, uri)
    end
  end
  def handle_info({:http, _, {:http_request, :GET, {:abs_path, "/"}, _}},
                  state = %CR{action: :recv_header}) do
    :ok = :inet.setopts(state.sock, active: :once)
    text = "404 Not Found.\ncpcache does not support directory listing.\n"
    reply_header = header_from_code(404, byte_size(text))
    :ok = :gen_tcp.send(state.sock, reply_header)
    :ok = :gen_tcp.send(state.sock, text)
    :ok = :gen_tcp.close(state.sock)
    {:stop, :normal, state}
  end

  def handle_info({:http, _, {:http_request, :GET, {:abs_path, "/robots.txt"}, _}},
                  state = %CR{action: :recv_header}) do
    :ok = :inet.setopts(state.sock, active: :once)
    text = "User-agent: *\nDisallow: /\n"
    reply_header = header_from_code(200, byte_size(text))
    :ok = :gen_tcp.send(state.sock, reply_header)
    :ok = :gen_tcp.send(state.sock, text)
    :ok = :gen_tcp.close(state.sock)
    {:stop, :normal, state}
  end

  def handle_info({:http, _, {:http_request, :GET, {:abs_path, "/favicon.ico"}, _}},
    state = %CR{action: :recv_header}) do
    :ok = :inet.setopts(state.sock, active: :once)
    reply_header = header_from_code(404)
    :ok = :gen_tcp.send(state.sock, reply_header)
    :ok = :gen_tcp.close(state.sock)
    {:stop, :normal, state}
  end

  def handle_info({:http, _, {:http_request, :GET, {:abs_path, path}, _}},
                  state = %CR{action: :recv_header}) do
    :ok = :inet.setopts(state.sock, active: :once)
    uri = case path do
      "/" <> rest -> URI.decode(rest)
    end
    init_state = init_state(state.distro, state.sock)
    {:noreply, %{init_state | request: {:GET, uri}}}
  end

  def handle_info({:http, _, :http_eoh},
                  state = %CR{action: :recv_header, request: {:POST, {arch, hn}}}) do
    :ok = :inet.setopts(state.sock, packet: :raw)
    new_state = %{state | headers: extract_headers(state.header_fields)}
    if new_state.headers.continue do
      :ok = :gen_tcp.send(state.sock, header_from_code(100))
    end
    content_length = new_state.headers.content_length
    maybe_content = cond do
      content_length > @max_body_size ->
        {:error, :body_too_large}
      content_length > 0 ->
        {:ok, content} = :gen_tcp.recv(new_state.sock, content_length, 500)
        {:ok, content}
      content_length == 0 ->
        {:ok, ""}
    end
    credentials = {Map.get(new_state.headers, :hmac), Map.get(new_state.headers, :timestamp)}
    authorization_status = with {:ok, content} <- maybe_content do
      case credentials do
        {nil, _} -> {:error, :hmac_missing}
        {_, nil} -> {:error, :timestamp_missing}
        {hmac, timestamp} -> authorize({hmac, timestamp}, content)
      end
    end
    case authorization_status do
      {:error, :body_too_large} ->
        _ = Logger.warn "Body exceeded max size of #{@max_body_size}."
        :ok = :gen_tcp.send(new_state.sock, header_from_code(413))
        :ok = :gen_tcp.close(new_state.sock)
      {:error, reason} ->
        _ = Logger.warn "Authorization failed: #{reason}"
        :ok = :gen_tcp.send(new_state.sock, header_from_code(403))
        :ok = :gen_tcp.close(new_state.sock)
      {:ok, content} ->
        _ = Logger.debug "Authorization succeeded."
        :ok = :gen_tcp.send(new_state.sock, header_from_code(200))
        :ok = :gen_tcp.close(new_state.sock)
        _ = Logger.debug "Write file for host #{hn}"
        path = Cpc.Utils.wanted_packages_dir(new_state.distro, arch)
        case File.mkdir_p(path) do
          :ok -> :ok
          {:error, :eexist} -> :ok
        end
        {:ok, file} = File.open(Path.join(path, hn), [:write])
        :ok = IO.write file, content
        :ok = File.close(file)
    end
    {:stop, :normal, new_state}
  end

  def handle_info({:http, _, :http_eoh}, state = %CR{action: :recv_header, request: {:GET, uri}}) do
    :ok = :inet.setopts(state.sock, active: :once)
    _ = Logger.debug "Received end of header."
    new_state = %{state | headers: extract_headers(state.header_fields)}
    complete_file_requested = new_state.headers.range_start == nil
    case get_filename(uri, new_state.distro) do
      {:database, db_url} ->
        serve_db_via_redirect(db_url, new_state)
      {:complete_file, filename} ->
        serve_via_cache(filename, new_state, new_state.headers.range_start)
      {:partial_file, filename} ->
        serve_via_partial_file(new_state, filename, uri)
      {:not_found, filename} when not complete_file_requested ->
        # No caching is used when the client requested only a part of the file that is not cached.
        # Caching would be relatively complex in this case: We would need to serve the HTTP request
        # immediately, while at the same time ensuring that the file stored locally starts at the
        # first byte of the complete file.
        _ = Logger.warn "Content range requested, but file is not cached: #{inspect filename}. " <>
                        "Serve request via redirect."
        serve_package_via_redirect(new_state, uri)
      {:not_found, filename} ->
        send new_state.serializer, {self(), :state?, filename}
        receive do
          :downloading ->
            _ = Logger.debug "Status of file is: :downloading"
            serve_via_growing_file(filename, new_state)
          :unknown ->
            _ = Logger.debug "Status of file is: :unknown"
            serve_via_http(filename, new_state, uri)
        end
    end
  end

  def handle_info({:http, _, {:http_request, :POST, {:abs_path, "/" <> path}, _}},
                  state = %CR{action: :recv_header}) do
    :ok = :inet.setopts(state.sock, active: :once)
    [arch, hn] = String.split(path, "/")
    _ = Logger.debug "Received POST request for architecture #{arch}, hostname #{hn}"
    init_state = init_state(state.distro, state.sock)
    {:noreply, %{init_state | request: {:POST, {arch, hn}}}}
  end

  def handle_info({:http, _, header_field = {:http_header, _, _, _, _}},
                  state = %CR{header_fields: hf}) do
    :ok = :inet.setopts(state.sock, active: :once)
    {:noreply, %{state | header_fields: [header_field|hf]}}
  end


  def handle_info({:tcp_closed, _}, %CR{action: {:filewatch, {_, n}, _, _}}) do
    # TODO this message is sometimes logged even though the transfer has completed.
    _ = Logger.info "Connection closed by client during data transfer. File #{n} is incomplete."
    {:stop, :normal, nil}
  end

  def handle_info({:tcp_closed, _sock}, _state) do
    _ = Logger.debug "Socket closed by client."
    {:stop, :normal, nil}
  end

  def handle_info({:EXIT, _, :normal}, state) do
    # Since we're trapping exits, we're notified if a linked process died, even if it died with
    # status :normal.
    {:noreply, state}
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
    {:noreply, %{state | action: :recv_header}}
  end

  def handle_cast({:file_complete, _}, state) do
    # Save to ignore: sometimes we notice the file has completed before this message is received,
    # i.e., if the timer happens to fire at the exact moment when the file has completed.
    _ = Logger.debug "Ignore file completion."
    {:noreply, state}
  end

  def handle_cast({:filesize_increased, _}, state) do
    # Can be ignored for the same reasons as :file_complete:
    # timer still informs us that the file has completed.
    _ = Logger.debug "Ignore file size increase."
    {:noreply, state}
  end

  defp finalize_download_from_growing_file(state, f, n, size, content_length) do
    _ = Logger.debug "Download from growing file complete."
    {:ok, _} = :file.sendfile(f, state.sock, size, content_length - size, [])
    _ = Logger.debug "Sendfile has completed."
    :ok = File.close(f)
    :ok = GenServer.cast(state.serializer, {:download_ended, n, self()})
    _ = Logger.debug "File is closed."
    ^content_length = File.stat!(n).size
  end

  def terminate(:normal, _state) do
    :ok
  end
  def terminate(status, state = %CR{sock: sock, sent_header: sent_header}) do
    _ = Logger.error "Failed serving request with status #{inspect status}. State is: #{inspect state}"
    if !sent_header do
        _ = :gen_tcp.send(sock, header_from_code(500))
    end
    _ = :gen_tcp.close(sock)
  end

end
