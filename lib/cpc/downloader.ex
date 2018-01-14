defmodule Cpc.Downloader do
  @validity 60 * 60 * 24 * 14 # check IPv6 support again after 14 days.
  require Logger
  use GenServer
  alias Cpc.Utils
  alias Cpc.Downloader, as: Dload
  defstruct url: nil,
            save_to: nil,
            start_from: nil,
            receiver: nil,
            start_time: nil


  # Process for downloading the given URL starting from byte start_from to the filename at path
  # save_to.
  #

  def try_all([url | fallbacks], save_to, start_from \\ nil) do
    {:ok, pid} = start_link(url, save_to, self(), start_from)
    receive do
      {:content_length, cl} ->
        {:ok, %{content_length: cl, downloader_pid: pid}}
      err = {:error, _reason} ->
        case fallbacks do
          [] ->
            err
          _ ->
            try_all(fallbacks, save_to, start_from)
        end
    end
  end

  def start_link(url, save_to, receiver, start_from \\ nil) do
    GenServer.start_link(__MODULE__, {to_charlist(url),
                                      to_charlist(save_to),
                                      receiver,
                                      start_from})
  end

  def init({url, save_to, receiver, start_from}) do
    send self(), :init
    {:ok, {url, save_to, receiver, start_from}}
  end

  def bandwidth_to_human_readable(bytes, microseconds) do
    bytes_per_second = bytes / (microseconds / 1000000)
    exponent = :erlang.trunc(:math.log2(bytes_per_second) / :math.log2(1024))
    prefix = case exponent do
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

  # Returns the download stats from the previous duration_seconds seconds.
  def stats_from(duration_seconds) do
    microsecs = :erlang.system_time(:micro_seconds) - duration_seconds * 1000000
    head = {DownloadSpeed, "repo.helios.click", :"$1", :"$2", :"$3"}
    {:atomic, data} = :mnesia.transaction(fn ->
      :mnesia.select(DownloadSpeed, [{head, [{:>, :"$2", microsecs}], [:"$$"]}])
    end)
    data
  end

  def measure_speed(request, content_length) do
    now = :erlang.system_time(:micro_seconds)
    diff = now - request.start_time
    _ = Logger.debug "Download of URL #{request.url} to file #{request.save_to} has completed."
    _ = Logger.debug "Content length is: #{content_length}"
    speed = bandwidth_to_human_readable(content_length, diff)
    secs = Float.round(diff / 1000000, 2)
    _ = Logger.debug "Received #{content_length} bytes in #{secs} seconds (#{speed})."
    host = URI.parse(to_string(request.url)).host
    {:atomic, :ok} = :mnesia.transaction(fn ->
      :mnesia.write({DownloadSpeed, host, content_length, request.start_time, diff})
    end)
    :ok
  end

  def supports_ipv6(url) do
    host = case :http_uri.parse(url) do
      {:ok, {_, _, host, _, _, _}} -> host
    end
    # Rather than just testing if the server has an AAAA record set, we actually want to find out if
    # it successfully replies to a GET request. Experience shows that some servers have their AAAA
    # record set and still won't allow clients to connect via IPv6, e.g. due to connection timeouts.
    db_result = :mnesia.transaction(fn ->
      :mnesia.read({Ipv6Support, host})
    end)
    prev_supported = case db_result do
      {:atomic, []} -> :unknown
      {:atomic, [{Ipv6Support, ^host, {then, supported_then}}]} ->
        now = :os.system_time(:second)
        diff = now - then
        expired = diff >= @validity
        if expired do
          :unknown
        else
          supported_then
        end
    end
    case prev_supported do
      :unknown ->
        _ = Logger.debug "Send HEAD request to test for IPv6 support."
        opts = [connect_options: [:inet6], connect_timeout: 2000]
        support = case :hackney.request(:head, url, [], "", opts) do
          {:ok, _, _} -> true
          _           -> false
        end
        {:atomic, :ok} = :mnesia.transaction(fn ->
          :mnesia.write({Ipv6Support, host, {:os.system_time(:second), support}})
        end)
        support
      false -> false
      true  -> true
    end
  end

  def handle_redirect(_headers, _request, 21) do
    raise "20 redirections exceeded."
  end
  def handle_redirect(headers, request, num_redirect) do
    headers = Utils.headers_to_lower(headers)
    location = :proplists.get_value("location", headers)
    _ = Logger.debug "Redirected to: #{location}"
    # TODO detect redirect cycle.
    init_get_request(%{request | url: location}, num_redirect)
  end

  def handle_success(headers, client, request) do
    headers = Utils.headers_to_lower(headers)
    content_length = :proplists.get_value("content-length", headers) |> String.to_integer
    Logger.debug "Content-length: #{content_length}"
    full_content_length = case :proplists.get_value("content-range", headers) do
      :undefined ->
        content_length
      header_line ->
        [_, length] = String.split(header_line, "/")
        String.to_integer(length)
    end
    send request.receiver, {:content_length, full_content_length}
    path = url_without_host(request.url)
    {:atomic, :ok} = :mnesia.transaction(fn ->
      :mnesia.write({ContentLength, {Path.basename(path)}, full_content_length})
    end)
    {:ok, file} = File.open(request.save_to, [:append, :raw])
    with :ok <- download(client, file) do
      measure_speed(request, content_length)
    end
  end

  def handle_failure(reason, client, request) do
    :ok = :hackney.close(client)
    handle_failure(reason, request)
  end
  def handle_failure(reason, request) do
    send request.receiver, {:error, reason}
    :ok = Logger.warn "Download of URL #{request.url} has failed: #{reason}"
  end

  def download(client, file) do
    # TODO check if the delayed_write option has some performance implications.
    case :hackney.stream_body(client) do
      {:ok, result} ->
        IO.binwrite(file, result)
        download(client, file)
      :done ->
        :ok = File.close(file)
      m = {:error, _reason} ->
        m
    end
  end

  def init_get_request(request, num_redirect \\ 0) do
    headers = case request.start_from do
                nil -> []
                0 -> []
                rs -> [{"Range", "bytes=#{rs}-"}]
              end
    # checking for IPv6 support will increase latency in some cases. Also, it has little use for
    # those with proper dual stack (i.e., anything other than dual stack lite). Perhaps we should
    # just remove this.
    opts = if supports_ipv6(request.url) do
      _ = Logger.debug "Use IPv6 for url #{request.url}"
      [connect_options: [:inet6]]
    else
      _ = Logger.debug "Use IPv4 for url #{request.url}"
      []
    end
    _ = Logger.debug "GET #{inspect request.url} with headers #{inspect headers} and opts #{inspect opts}"
    case :hackney.request(:get, request.url, headers, "", opts) do
      {:ok, status, headers, client} ->
        case status do
          200 ->
            handle_success(headers, client, request)
          206 ->
            handle_success(headers, client, request)
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
            handle_failure(status, client, request)
        end
      {:error, reason} ->
        handle_failure(reason, request)
    end
  end

  def handle_info(:init, {url, save_to, receiver, start_from}) do
    start_time = :erlang.system_time(:micro_seconds)
    request = %Dload{url: url,
                   save_to: save_to,
                   start_from: start_from,
                   receiver: receiver,
                   start_time: start_time}
    init_get_request(request)
    {:stop, :normal, request}
  end

  defp url_without_host(url) do
    url |> to_string |> path_to_segments |> Enum.drop(-2) |> Enum.reverse |> Path.join
  end

  defp path_to_segments(path) do
    [head | tail] = String.split(path, "/")
    reverse_and_discard_empty(tail, [head])
  end

  defp reverse_and_discard_empty([], acc), do: acc
  defp reverse_and_discard_empty([head], acc), do: [head | acc]
  defp reverse_and_discard_empty(["" | tail], acc), do: reverse_and_discard_empty(tail, acc)
  defp reverse_and_discard_empty([head | tail], acc) do
    reverse_and_discard_empty(tail, [head | acc])
  end

end
