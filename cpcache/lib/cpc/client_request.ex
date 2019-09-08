defmodule Cpc.ClientRequest do
  @serializer_timeout "Timeout while waiting for serializer to reply."
  alias Cpc.ClientRequest, as: CR
  alias Cpc.Filewatcher
  alias Cpc.Utils
  alias Cpc.MirrorSelector
  alias Cpc.TableAccess
  require Logger
  use GenServer

  defstruct sock: nil,
            # true if we replied by sending the header to the client
            sent_header: false,
            action: nil,
            downloader_pid: nil,
            timer_ref: nil,
            # the unchanged headers, in the form we received them
            header_fields: [],
            # a map containing the relevant data extracted from above headers
            headers: %{},
            request: nil,
            waiting_for_no_dependencies_left: false

  def start_link(sock) do
    GenServer.start_link(__MODULE__, init_state(sock))
  end

  defp init_state(sock) do
    %CR{sock: sock, sent_header: false, action: :recv_header}
  end

  @impl true
  def init(state) do
    Process.flag(:trap_exit, true)
    {:ok, state}
  end

  defp premature_close(filename) do
    "Connection closed by client during data transfer. File #{filename} is incomplete."
  end

  defp is_localrepo(uri) do
    [localrepos: localrepos] = :ets.lookup(:cpc_config, :localrepos)
    [repo | _] = Path.split(uri)
    Enum.member?(localrepos, repo)
  end

  defp get_filename(uri) do
    cache_dir =
      case :ets.lookup(:cpc_config, :cache_directory) do
        [{:cache_directory, cd}] -> Path.join(cd, "pkg")
      end

    filename = Path.join(cache_dir, uri)
    dirname = Path.dirname(filename)
    basename = Path.basename(filename)
    is_database = String.ends_with?(basename, ".db")
    is_localrepo = is_localrepo(uri)

    {partial_file_exists, complete_file_exists} =
      case {is_database, is_localrepo} do
        {true, false} ->
          {false, false}

        _ ->
          case File.stat(Path.join(dirname, basename)) do
            {:error, :enoent} ->
              {false, false}

            {:ok, %File.Stat{size: 0}} ->
              {false, false}

            {:ok, %File.Stat{size: size}} ->
              if is_localrepo do
                {true, true}
              else
                case content_length(uri) do
                  {:ok, ^size} ->
                    {true, true}

                  {:ok, cl} when cl > size ->
                    {true, false}

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
      end

    case {is_localrepo, is_database, complete_file_exists, partial_file_exists} do
      {true, _, true, _} ->
        {:complete_file, filename}

      {true, _, false, _} ->
        {:not_found, Path.join([dirname, basename])}

      {false, true, _, _} ->
        # no attempt is made to select the best mirror: since we use redirects for database
        # files, we just use the first mirror.
        [mirror | _] = MirrorSelector.get_all()
        {:database, Path.join(mirror, uri)}

      {false, false, false, false} ->
        {:not_found, Path.join([dirname, basename])}

      {false, false, true, _} ->
        {:complete_file, filename}

      {false, false, false, true} ->
        {:partial_file, Path.join([dirname, basename])}
    end
  end

  defp extract_headers(headers) do
    init_map = %{continue: false, range_start: nil}

    Enum.reduce(headers, init_map, fn
      {:http_header, _, :"Content-Length", _, value}, acc ->
        Map.put(acc, :content_length, String.to_integer(value))

      {:http_header, _, "Expect", _, "100-continue"}, acc ->
        Map.put(acc, :continue, true)

      {:http_header, _, "Timestamp", _, timestamp}, acc ->
        # TODO is this actually used?
        Map.put(acc, :timestamp, String.to_integer(timestamp))

      {:http_header, _, :Range, _, range}, acc ->
        Map.put(
          acc,
          :range_start,
          case range do
            "bytes=" <> rest ->
              {start, "-"} = Integer.parse(rest)
              start
          end
        )

      m, acc ->
        _ = Logger.debug("Ignored: #{inspect(m)}")
        acc
    end)
  end

  defp header(full_content_length, range_start) do
    content_length =
      case range_start do
        nil -> full_content_length
        rs -> full_content_length - rs
      end

    content_range_line =
      case range_start do
        nil ->
          ""

        rs ->
          range_end = full_content_length - 1
          "Content-Range: bytes #{rs}-#{range_end}/#{full_content_length}\r\n"
      end

    date = to_string(:httpd_util.rfc1123_date())

    """
    HTTP/1.1 200 OK\r
    Server: cpcache\r
    Date: #{date}\r
    Content-Type: application/octet-stream\r
    Content-Length: #{content_length}\r
    """ <> content_range_line <> "\r\n"
  end

  def default_header(text, content_length) do
    date = to_string(:httpd_util.rfc1123_date())

    """
    HTTP/1.1 #{text}\r
    Server: cpcache\r
    Date: #{date}\r
    Content-Length: #{content_length}\r
    \r
    """
  end

  defp header_from_code(code, content_length \\ 0)
  defp header_from_code(100, cl), do: default_header("100 Continue", cl)
  defp header_from_code(200, cl), do: default_header("200 OK", cl)
  defp header_from_code(403, cl), do: default_header("403 Forbidden", cl)
  defp header_from_code(404, cl), do: default_header("404 Not Found", cl)
  defp header_from_code(413, cl), do: default_header("413 Payload Too Large", cl)
  defp header_from_code(500, cl), do: default_header("500 Internal Server Error", cl)

  defp header_301(location) do
    date = to_string(:httpd_util.rfc1123_date())

    "HTTP/1.1 301 Moved Permanently\r\n" <>
      "Server: cpcache\r\n" <>
      "Date: #{date}\r\n" <> "Content-Length: 0\r\n" <> "Location: #{location}\r\n" <> "\r\n"
  end

  def mirror_urls(request_uri) do
    Enum.map(MirrorSelector.get_all(), fn mirror_url ->
      mirror_url |> String.replace_suffix("/", "") |> Path.join(request_uri)
    end)
  end

  def headers_from_url(url) do
    _ = Logger.warn("Sending HEAD request to #{url}")

    case :hackney.request(:head, url) do
      {:ok, 200, headers} -> {:ok, Utils.headers_to_lower(headers)}
      {:ok, 404, _headers} -> {:error, :not_found}
    end
  end

  def headers_until_success(request_uri) do
    Utils.repeat_until_ok(&headers_from_url/1, mirror_urls(request_uri))
  end

  # Given the requested URI, fetch the full content-length from the server.
  # req_uri must be the URI as requested by the user, not the URI that will be used to GET the file
  # via HTTP.
  def content_length(req_uri) do
    result = TableAccess.get("content_length", Path.basename(req_uri))

    case result do
      {:ok, content_length} ->
        _ = Logger.debug("Retrieved content-length for #{req_uri} from cache.")
        {:ok, content_length}

      {:error, :not_found} ->
        _ = Logger.debug("Retrieve content-length for #{req_uri} via HTTP HEAD request.")

        with {:ok, headers} <- headers_until_success(req_uri) do
          content_length = :proplists.get_value("content-length", headers) |> String.to_integer()
          TableAccess.add("content_length", Path.basename(req_uri), content_length)
          _ = Logger.debug("Saved to database: content-length #{content_length} for #{req_uri}")
          {:ok, content_length}
        end
    end
  end

  defp serve_via_http(filename, state, uri) do
    _ = Logger.info("Serve file via HTTP: #{filename}")
    urls = mirror_urls(uri)

    case Cpc.Downloader.try_all(urls, filename, 0) do
      {:ok, %{content_length: content_length, downloader_pid: pid}} ->
        TableAccess.add("content_length", Path.basename(uri), content_length)

        reply_header = header(content_length, state.headers.range_start)
        :ok = :gen_tcp.send(state.sock, reply_header)
        _ = Logger.debug("Sent header: #{inspect(reply_header)}")
        file = File.open!(filename, [:read, :raw])

        start_size =
          case state.headers.range_start do
            nil -> 0
            rs -> rs
          end

        {:ok, _} = Filewatcher.start_link(self(), filename, content_length, start_size)
        action = {:filewatch, {file, filename}, content_length, 0}
        {:noreply, %{state | sent_header: true, action: action, downloader_pid: pid}}

      {:error, reason} ->
        _ = Logger.warn("Failed to download file: #{inspect(reason)}")
        _ = Logger.debug("Remove file #{filename}.")
        # The empty file was previously created by Cpc.Serializer.
        :ok = File.rm(filename)
        reply_header = header_from_code(404)
        :ok = :gen_tcp.send(state.sock, reply_header)
        {:noreply, %{state | sent_header: true, action: :recv_header}}
    end
  end

  defp serve_package_via_redirect(state, uri) do
    [url | _] = mirror_urls(uri)
    _ = Logger.info("Serve package via HTTP redirect from #{url}.")
    :ok = :gen_tcp.send(state.sock, header_301(url))
    {:noreply, %{state | sent_header: true, action: :recv_header}}
  end

  defp serve_db_via_redirect(db_url, state) do
    _ = Logger.info("Serve database file #{db_url} via HTTP redirect.")
    :ok = :gen_tcp.send(state.sock, header_301(db_url))
    {:noreply, %{state | sent_header: true, action: :recv_header}}
  end

  defp serve_via_cache(filename, state, range_start) do
    _ = Logger.info("Serve file from cache: #{filename}")
    content_length = File.stat!(filename).size
    reply_header = header(content_length, range_start)
    :ok = :gen_tcp.send(state.sock, reply_header)

    case range_start do
      nil ->
        {:ok, ^content_length} = :file.sendfile(filename, state.sock)

      rs when rs == content_length ->
        _ = Logger.warn("File is already fully retrieved by the client.")
        :ok

      rs when rs < content_length ->
        _ = Logger.debug("Send partial file, from #{rs} until end.")
        f = File.open!(filename, [:read, :raw])
        {:ok, _} = :file.sendfile(f, state.sock, range_start, content_length - rs, [])
        :ok = File.close(f)
    end

    _ = Logger.debug("Download from cache complete.")
    {:noreply, %{state | sent_header: true, action: :recv_header}}
  end

  defp serve_via_growing_file(filename, state) do
    %CR{request: {:GET, uri}} = state
    {:ok, full_content_length} = content_length(uri)
    {:ok, _} = Filewatcher.start_link(self(), filename, full_content_length)

    _ =
      Logger.info(
        "File #{filename} is already being downloaded, initiate download from growing file."
      )

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

    retrieval_start_method =
      case state.headers.range_start do
        # send file starting from 0th byte.
        nil ->
          {:file, 0}

        rs ->
          cond do
            rs < filesize ->
              {:file, state.headers.range_start}

            rs == filesize ->
              {:http, state.headers.range_start}

            rs > filesize ->
              # TODO notice that in this case, we need to make sure how to maintain the following
              # invariant: If a file is stored by cpcache, for 0 <= n <= filesize, the first n bytes
              # of the locally stored file always correspond to the first n bytes of the file stored
              # on a remote mirror.
              # (in other words: while files may be incomplete, they are always stored in sequence).
              raise "Not implemented yet"
          end
      end

    _ = Logger.debug("Start of requested content-range: #{inspect(state.headers.range_start)}")

    {start_http_from_byte, send_from_cache} =
      case retrieval_start_method do
        {:file, from} ->
          send_ = fn ->
            _ = Logger.debug("Sending #{filesize - from} bytes from cached file.")

            File.open(filename, [:read, :raw], fn raw_file ->
              {:ok, _} = :file.sendfile(raw_file, state.sock, from, filesize - from, [])
            end)
          end

          {filesize, send_}

        {:http, from} ->
          {from, fn -> :ok end}
      end

    _ = Logger.debug("Start HTTP download from byte #{start_http_from_byte}")
    range_start = state.headers.range_start

    case content_length(uri) do
      {:ok, cl} when cl == filesize ->
        _ = Logger.warn("The entire file has already been downloaded by the server.")
        serve_via_cache(filename, state, range_start)

      {:ok, cl} when cl == range_start ->
        # The client requested a content range, although he already has the entire file.
        reply_header = header(cl, range_start)
        :ok = :gen_tcp.send(state.sock, reply_header)
        _ = Logger.debug("Sent header: #{reply_header}")
        _ = Logger.warn("File is already fully retrieved by the client.")
        {:noreply, %{state | sent_header: true, action: :recv_header}}

      {:ok, _} ->
        urls = mirror_urls(uri)

        # TODO not very well-tested: What happens when we successfully download the first few bytes
        # from the first mirror, then this mirror fails and we need to swap to the next mirror?
        case Cpc.Downloader.try_all(urls, filename, start_http_from_byte) do
          {:ok, %{content_length: content_length, downloader_pid: pid}} ->
            file = File.open!(filename, [:read, :raw])
            reply_header = header(content_length, range_start)
            :ok = :gen_tcp.send(state.sock, reply_header)
            _ = Logger.debug("Sent header: #{reply_header}")
            send_from_cache.()

            {:ok, _} =
              Filewatcher.start_link(self(), filename, content_length, start_http_from_byte)

            action = {:filewatch, {file, filename}, content_length, start_http_from_byte}

            {:noreply,
             %{
               state
               | sent_header: true,
                 action: action,
                 downloader_pid: pid
             }}

          {:error, reason} ->
            reply_header =
              case reason do
                404 -> header_from_code(404)
                _ -> header_from_code(500)
              end

            :ok = :gen_tcp.send(state.sock, reply_header)
            _ = Logger.debug("Sent header: #{reply_header}")
            {:noreply, %{state | sent_header: true, action: :recv_header}}
        end

      {:error, :not_found} ->
        reply_header = header_from_code(404)
        :ok = :gen_tcp.send(state.sock, reply_header)
        _ = Logger.debug("Sent header: #{reply_header}")
        # TODO what are we supposed to do if we can't fetch the content length? Probably the same
        # as when we can't successfully serve the GET request, i.e., try again with mirror n + 1.
        {:noreply, %{state | sent_header: true, action: :recv_header}}
    end
  end

  defp serve_via_partial_file(state, filename, uri) do
    # The requested file already exists, but its size is smaller than the content length
    send(Cpc.Serializer, {self(), :state?, filename})

    receive do
      :downloading ->
        serve_via_growing_file(filename, state)

      :unknown ->
        _ = Logger.info("Serve file partly via cache, partly via HTTP: #{filename}")
        serve_via_cache_and_http(state, filename, uri)

      :invalid_path ->
        :ok = :gen_tcp.send(state.sock, header_from_code(404))
        {:stop, :normal, state}
    after
      500 ->
        raise @serializer_timeout
    end
  end

  @impl true
  def handle_info(
        {:http, _, {:http_request, :GET, {:abs_path, "/"}, _}},
        state = %CR{action: :recv_header}
      ) do
    :ok = :inet.setopts(state.sock, active: :once)
    text = "404 Not Found.\ncpcache does not support directory listing.\n"
    reply_header = header_from_code(404, byte_size(text))
    :ok = :gen_tcp.send(state.sock, reply_header)
    :ok = :gen_tcp.send(state.sock, text)
    :ok = :gen_tcp.close(state.sock)
    {:stop, :normal, state}
  end

  @impl true
  def handle_info(
        {:http, _, {:http_request, :GET, {:abs_path, path}, _}},
        state = %CR{action: :recv_header}
      ) do
    :ok = :inet.setopts(state.sock, active: :once)

    uri =
      case path do
        "/" <> rest -> URI.decode(rest)
      end

    init_state = init_state(state.sock)
    {:noreply, %{init_state | request: {:GET, uri}}}
  end

  @impl true
  def handle_info({:http, _, :http_eoh}, state = %CR{action: :recv_header, request: {:GET, uri}}) do
    :ok = :inet.setopts(state.sock, active: :once)
    _ = Logger.debug("Received end of header.")
    new_state = %{state | headers: extract_headers(state.header_fields)}
    complete_file_requested = new_state.headers.range_start == nil

    case get_filename(uri) do
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
        _ =
          Logger.warn(
            "Content range requested, but file is not cached: #{inspect(filename)}. " <>
              "Serve request via redirect."
          )

        serve_package_via_redirect(new_state, uri)

      {:not_found, filename} ->
        send(Cpc.Serializer, {self(), :state?, filename})

        receive do
          :downloading ->
            _ = Logger.debug("Status of file is: :downloading")
            serve_via_growing_file(filename, new_state)

          :unknown ->
            _ = Logger.debug("Status of file is: :unknown")
            serve_via_http(filename, new_state, uri)

          :invalid_path ->
            :ok = :gen_tcp.send(state.sock, header_from_code(404))
            {:stop, :normal, state}
        after
          500 ->
            raise @serializer_timeout
        end
    end
  end

  @impl true
  def handle_info(
        {:http, _, header_field = {:http_header, _, _, _, _}},
        state = %CR{header_fields: hf}
      ) do
    :ok = :inet.setopts(state.sock, active: :once)
    {:noreply, %{state | header_fields: [header_field | hf]}}
  end

  @impl true
  def handle_info({:tcp_closed, _sock}, state) do
    _ = Logger.debug("Socket closed by client.")

    case GenServer.call(Cpc.Serializer, :client_closed) do
      :ok ->
        # No other clients depend on this process, we may stop.
        {:stop, :normal, state}

      :wait_for_signal ->
        # Other clients depend on this process: We may not stop this process until the Serializer tells us to.
        {:noreply, %{state | waiting_for_no_dependencies_left: true}}
    end
  end

  @impl true
  def handle_info({:EXIT, _, :normal}, state) do
    # Since we're trapping exits, we're notified if a linked process died, even if it died with
    # status :normal.
    {:noreply, state}
  end

  @impl true
  def handle_cast(:no_dependencies_left, state = %CR{waiting_for_no_dependencies_left: true}) do
    # No other clients depend on this process anymore, we may now stop.
    {:stop, :normal, state}
  end

  @impl true
  def handle_cast(:no_dependencies_left, state = %CR{waiting_for_no_dependencies_left: false}) do
    # We don't care about this message since we are not waiting for an event telling us that we can stop.
    {:noreply, state}
  end

  @impl true
  def handle_cast({:filesize_increased, _}, state = %CR{waiting_for_no_dependencies_left: true}) do
    # Nothing to do: We just leave this process running, waiting until all dependencies
    # don't need this process anymore.
    # TODO this is messy, we should probably refactor this so that processes get the :filesize_increased message
    # only if they need this message.
    {:noreply, state}
  end

  @impl true
  def handle_cast(
        {:filesize_increased, {n1, prev_size, new_size}},
        state = %CR{action: {:filewatch, {f, n2}, content_length, _size}}
      )
      when n1 == n2 do
    case :file.sendfile(f, state.sock, prev_size, new_size - prev_size, []) do
      {:ok, _} ->
        {:noreply, %{state | action: {:filewatch, {f, n2}, content_length, new_size}}}

      {:error, :closed} ->
        _ = Logger.info(premature_close(n1))
        {:stop, :normal, state}
    end
  end

  @impl true
  def handle_cast(
        {:file_complete, {n1, _prev_size, new_size}},
        state = %CR{action: {:filewatch, {f, n2}, content_length, size}}
      )
      when n1 == n2 do
    ^new_size = content_length
    finalize_download_from_growing_file(state, f, n2, size, content_length)
    {:noreply, %{state | action: :recv_header}}
  end

  @impl true
  def handle_cast({:file_complete, _}, state) do
    # Save to ignore: sometimes we notice the file has completed before this message is received,
    # i.e., if the timer happens to fire at the exact moment when the file has completed.
    _ = Logger.debug("Ignore file completion.")
    {:noreply, state}
  end

  @impl true
  def handle_cast({:filesize_increased, _}, state) do
    # Can be ignored for the same reasons as :file_complete:
    # timer still informs us that the file has completed.
    _ = Logger.debug("Ignore file size increase.")
    {:noreply, state}
  end

  defp finalize_download_from_growing_file(state, f, n, size, content_length) do
    _ = Logger.debug("Download from growing file complete.")

    case :file.sendfile(f, state.sock, size, content_length - size, []) do
      {:ok, _} ->
        _ = Logger.debug("sendfile() has completed successfully.")

      {:error, :einval} ->
        _ = Logger.warn("sendfile() has failed (EINVAL). Did the client close the connection?")
    end

    :ok = File.close(f)
    :ok = GenServer.cast(Cpc.Serializer, {:download_ended, n, self()})
    _ = Logger.debug("File is closed.")
    ^content_length = File.stat!(n).size
  end

  @impl true
  def terminate(reason, state = %CR{sock: sock, sent_header: sent_header, downloader_pid: pid}) do
    case reason do
      :normal ->
        :ok

      status ->
        _ =
          Logger.error(
            "Failed serving request with status #{inspect(status)}. State is: #{inspect(state)}"
          )

        if !sent_header do
          _ = :gen_tcp.send(sock, header_from_code(500))
        end

        _ = :gen_tcp.close(sock)
    end

    # Ensure the downloader process is terminated before this process:
    # The downloader process is responsible for writing to the file, but we can't have any process
    # writing to the file after client_request terminates, because after client_request terminates,
    # the file is marked as not being downloaded.
    if pid do
      _ = Logger.debug("Kill downloader process.")
      :erlang.exit(pid, :kill)
    end
  end
end
