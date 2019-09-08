defmodule Cpc.Downloader do
  require Logger
  use GenServer
  alias Cpc.Utils
  alias Cpc.Downloader, as: Dload
  alias Cpc.TableAccess

  # 100 kb/s = 0.1024 bytes per microsecond
  @speed_limit_dev 0.1024

  defstruct uri: nil,
            save_to: nil,
            start_from: nil,
            receiver: nil,
            start_time: nil

  # Process for downloading the given URL starting from byte start_from to the filename at path
  # save_to.

  def start_link(url, save_to, receiver, start_from \\ nil) do
    uri = URI.parse(to_string(url))

    GenServer.start_link(
      __MODULE__,
      {uri, to_charlist(save_to), receiver, start_from}
    )
  end

  @impl true
  def init({uri, save_to, receiver, start_from}) do
    send(self(), :init)
    {:ok, {uri, save_to, receiver, start_from}}
  end

  @impl true
  def handle_info(:init, {uri = %URI{}, save_to, receiver, start_from}) do
    start_time = :erlang.system_time(:micro_seconds)

    request = %Dload{
      uri: uri,
      save_to: save_to,
      start_from: start_from,
      receiver: receiver,
      start_time: start_time
    }

    init_get_request(request)
    {:stop, :normal, request}
  end

  def try_all([url | fallbacks], save_to, start_from \\ nil) do
    {:ok, pid} = start_link(url, save_to, self(), start_from)
    ref = Process.monitor(pid)

    receive do
      {:DOWN, ^ref, _, _, reason} ->
        # Notice that we raise instead of just returning {:error, reason}.
        # This is due to the fact that the process exiting is most likely due to a bug in the Downloader process,
        # and not some problem with the mirror. By raising, the client_request process exits and returns 500, instead
        # of just returning 404.
        raise("Downloader process failed with reason #{inspect(reason)}")

      {:content_length, cl} ->
        Process.demonitor(ref, [:flush])
        {:ok, %{content_length: cl, downloader_pid: pid}}

      err = {:error, _reason} ->
        Process.demonitor(ref, [:flush])

        case fallbacks do
          [] ->
            err

          _ ->
            try_all(fallbacks, save_to, start_from)
        end
    end
  end

  def bandwidth_to_human_readable(_bytes, microseconds) when microseconds <= 0 do
    raise "duration must be positive to provide meaningful values"
  end

  def bandwidth_to_human_readable(0, _microseconds) do
    "0 B/s"
  end

  def bandwidth_to_human_readable(bytes, microseconds) do
    bytes_per_second = bytes / (microseconds / 1_000_000)
    exponent = :erlang.trunc(:math.log2(bytes_per_second) / :math.log2(1024))

    prefix =
      case exponent do
        0 -> {:ok, ""}
        1 -> {:ok, "Ki"}
        2 -> {:ok, "Mi"}
        3 -> {:ok, "Gi"}
        4 -> {:ok, "Ti"}
        5 -> {:ok, "Pi"}
        6 -> {:ok, "Ei"}
        7 -> {:ok, "Zi"}
        8 -> {:ok, "Yi"}
        _ -> {:error, :too_large}
      end

    case prefix do
      {:ok, prefix} ->
        quantity = Float.round(bytes_per_second / :math.pow(1024, exponent), 2)
        unit = "#{prefix}B/s"
        "#{quantity} #{unit}"

      {:error, :too_large} ->
        "#{bytes_per_second} B/s"
    end
  end

  def measure_speed(request = %Dload{}, content_length) do
    now = :erlang.system_time(:micro_seconds)
    diff = now - request.start_time

    _ =
      Logger.debug(
        "Download of URL has completed: #{request.uri} to file #{request.save_to} has completed."
      )

    _ = Logger.debug("Content length is: #{content_length}")
    speed = bandwidth_to_human_readable(content_length, diff)
    secs = Float.round(diff / 1_000_000, 2)
    _ = Logger.debug("Received #{content_length} bytes in #{secs} seconds (#{speed}).")

    :ok
  end

  def handle_result(status, headers, conn_ref, request = %Dload{}, num_redirect) do
    case status do
      200 ->
        handle_success(headers, conn_ref, request)

      206 ->
        handle_success(headers, conn_ref, request)

      301 ->
        handle_redirect(headers, request, num_redirect + 1)

      302 ->
        handle_redirect(headers, request, num_redirect + 1)

      303 ->
        handle_redirect(headers, request, num_redirect + 1)

      307 ->
        handle_redirect(headers, request, num_redirect + 1)

      308 ->
        handle_redirect(headers, request, num_redirect + 1)

      status ->
        handle_failure(status, conn_ref, request)
    end
  end

  def handle_redirect(_headers, _request, 21) do
    raise "20 redirections exceeded."
  end

  def handle_redirect(headers, request = %Dload{}, num_redirect) do
    headers = Utils.headers_to_lower(headers)
    location = :proplists.get_value("location", headers)
    _ = Logger.debug("Redirected to: #{location}")
    init_get_request(%{request | uri: URI.parse(location)}, num_redirect)
  end

  def handle_success(headers, client, request = %Dload{}) do
    headers = Utils.headers_to_lower(headers)
    content_length = :proplists.get_value("content-length", headers) |> String.to_integer()
    Logger.debug("Content-length: #{content_length}")

    full_content_length =
      case :proplists.get_value("content-range", headers) do
        :undefined ->
          content_length

        header_line ->
          [_, length] = String.split(header_line, "/")
          String.to_integer(length)
      end

    send(request.receiver, {:content_length, full_content_length})

    TableAccess.add("content_length", Path.basename(request.uri.path), full_content_length)

    {:ok, file} = File.open(request.save_to, [:append, :raw])

    throttle_downloads =
      case Application.fetch_env(:cpcache, :throttle_downloads) do
        {:ok, true} -> true
        {:ok, false} -> false
        :error -> false
      end

    with :ok <- download(client, file, throttle_downloads) do
      measure_speed(request, content_length)
    end
  end

  def handle_failure(reason, client, request = %Dload{}) do
    _ = Logger.error("Error while handling HTTP request: #{inspect(reason)}")
    :ok = :hackney.close(client)
    handle_failure(reason, request)
  end

  def handle_failure(reason, request = %Dload{}) do
    send(request.receiver, {:error, reason})
  end

  def download(client, file, throttle \\ false, size \\ 0, timestamp \\ :erlang.timestamp()) do
    case :hackney.stream_body(client) do
      {:ok, result} ->
        IO.binwrite(file, result)
        new_size = size + byte_size(result)

        if throttle do
          # Apply speed limit during test cases:
          # To avoid unnecessary load on remote mirrors, but also to achieve a certain reproducibility for our
          # test cases.
          diff = :timer.now_diff(:erlang.timestamp(), timestamp)
          sleep_for = new_size / @speed_limit_dev - diff

          if sleep_for > 0 do
            :ok = :timer.sleep(trunc(sleep_for / 1000))
          end
        end

        download(client, file, throttle, new_size, timestamp)

      :done ->
        _ = Logger.debug("Closing file.")
        :ok = File.close(file)

      # Apparently, hackney closes the socket automatically when :done is sent. Explicitly closing the client
      # at this point would result in an error.

      {:error, reason} ->
        raise("Error while downloading file: #{inspect(reason)}")
    end
  end

  defp get_headers(start_from, host) do
    range_headers =
      case start_from do
        nil -> []
        0 -> []
        rs -> [{"Range", "bytes=#{rs}-"}]
      end

    [{"Host", host} | range_headers]
  end

  def init_get_request(request = %Dload{uri: uri = %URI{}}, num_redirect \\ 0) do
    headers = get_headers(request.start_from, uri.host)
    _ = Logger.debug("GET #{inspect(uri)} with headers #{inspect(headers)}")

    Logger.debug("Attempt to fetch file: #{uri}")

    case hackney_connect_dual_stack(uri) do
      {:ok, {_protocol, conn_ref}} ->
        hackney_request = {:get, uri.path, headers, ""}

        case :hackney.send_request(conn_ref, hackney_request) do
          {:error, reason} ->
            handle_failure(reason, conn_ref, request)

          {:ok, status, headers, ^conn_ref} ->
            _ = Logger.debug("Status for url #{inspect(uri)}: #{status}")
            handle_result(status, headers, conn_ref, request, num_redirect)
        end

      {:error, reason} ->
        handle_failure(reason, request)
    end
  end

  def connect_hackney(uri, ip_address, protocol, connect_timeout, _pid) do
    ip_address =
      case :inet.ntoa(ip_address) do
        {:error, :einval} -> raise("Unable to parse ip address: #{inspect(ip_address)}")
        x -> x
      end

    Logger.debug("ip is: #{inspect(ip_address)}, protocol: #{protocol}")

    opts = [connect_timeout: connect_timeout, ssl_options: [{:verify, :verify_none}]]

    transport =
      case uri.port do
        80 -> :hackney_tcp
        443 -> :hackney_ssl
      end

    case :hackney.connect(transport, ip_address, uri.port, opts) do
      {:ok, conn_ref} ->
        Logger.debug("Successfully connected to #{uri.host} via #{inspect(ip_address)}")
        {:ok, {protocol, conn_ref}}

      {:error, reason} ->
        Logger.warn("Error while attempting to connect to #{uri.host}: #{inspect(reason)}")
        {:error, {protocol, reason}}
    end
  end

  def connect_hackney_inet(), do: &connect_hackney(&1, &2, :inet, &3, &4)
  def connect_hackney_inet6(), do: &connect_hackney(&1, &2, :inet6, &3, &4)

  def hackney_connect_dual_stack(url) do
    transfer_ownership_to = fn pid, {:ok, {_protocol, conn_ref}} ->
      :ok = :hackney.controlling_process(conn_ref, pid)
    end

    Eyepatch.resolve(
      url,
      connect_hackney_inet(),
      connect_hackney_inet6(),
      &:inet.getaddrs/2,
      transfer_ownership_to
    )
  end

  def transfer_ownership_to(new_pid, {:ok, {_protocol, conn_ref}}) do
    :hackney.controlling_process(conn_ref, new_pid)
  end

  def transfer_ownership_to(_new_pid, {:error, _}) do
    :ok
  end
end
