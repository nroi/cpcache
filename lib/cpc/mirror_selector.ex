defmodule Cpc.MirrorSelector do
  use GenServer
  require Logger
  @json_path "https://www.archlinux.org/mirrors/status/json/"
  @retry_after 5000
  @max_attempts 3

  # The module used to test the latency of all available mirrors in order to sort them and provide a
  # selection of low-latency mirrors.

  def start_link() do
    GenServer.start_link(__MODULE__, nil, name: __MODULE__)
  end

  # TODO maybe we should allow to maintain a sort of grey-list:
  # a list which basically says "do not use this mirror for the next x seconds".
  # this could be useful for instance if a mirror is having temporary difficulties or it's just too
  # slow.
  # when downloading a large file and the speed is below a certain threshold, we could then greylist
  # this mirror, and restart the download from a non-greylisted mirror. make sure that, in case the
  # internet connection is just slow, we don't populate the greylist with all mirrors: perhaps we
  # should limit the greylist to not more than half of the filtered mirrors.
  # TODO implement the feature to swap the server while it's downloading, if the download is too
  # slow: this feature would be really awesome!

  def init(nil) do
    # Start with the predefined mirrors. We will add "better" mirrors later, but for now, we want to
    # have some mirrors available in case a mirror is requested before the process to find the best
    # mirrors has completed.
    [mirrors: predefined] = :ets.lookup(:cpc_config, :mirrors)

    renew_interval =
      case :ets.lookup(:cpc_config, :mirror_selection) do
        [mirror_selection: {:auto, %{test_interval: -1}}] ->
          :never

        [mirror_selection: {:auto, %{test_interval: hours}}] when is_number(hours) ->
          _ = Logger.debug("Run new test after #{hours} hours have expired.")
          hours * 60 * 60 * 1000

        _ ->
          :never
      end

    :ets.insert(:cpc_state, {:mirrors, predefined})

    if renew_interval != :never do
      send(self(), :init)
    end

    {:ok, renew_interval}
  end

  def get_all() do
    [mirrors: mirrors] = :ets.lookup(:cpc_state, :mirrors)
    mirrors
  end

  def get_json(num_attempts) when num_attempts == @max_attempts do
    # failed to fetch the most recent mirror status from remote: see if we can fetch an older
    # version from cache.
    _ =
      Logger.warn(
        "Max. number of attempts exceeded. Checking for a cached version of " <>
          "the mirror data…"
      )

    db_result =
      :mnesia.transaction(fn ->
        :mnesia.read({MirrorsStatus, "most_recent"})
      end)

    case db_result do
      {:atomic, [{MirrorsStatus, "most_recent", {_timestamp, map}}]} ->
        _ = Logger.warn("Retrieved mirror data from cache.")
        {:ok, map}

      _ ->
        _ = Logger.warn("No mirror data found in cache.")
        :error
    end
  end

  def get_json(num_attempts) when num_attempts < @max_attempts do
    case json_from_remote() do
      result = {:ok, _json} ->
        result

      other ->
        Logger.warn("Unable to fetch mirror data from #{@json_path}: #{inspect(other)}")
        Logger.warn("Retry in #{@retry_after} milliseconds")
        :timer.sleep(@retry_after)
        get_json(num_attempts + 1)
    end
  end

  def handle_info(:init, renew_interval) do
    case get_json(0) do
      {:ok, map} ->
        sorted = sorted_mirrors(map)
        [mirrors: predefined] = :ets.lookup(:cpc_config, :mirrors)
        :ets.insert(:cpc_state, {:mirrors, sorted ++ predefined})
        Logger.debug("Mirrors sorted: #{inspect(sorted)}")

        case renew_interval do
          :never ->
            :ok

          millisecs when is_integer(millisecs) ->
            :erlang.send_after(millisecs, self(), :init)
        end

        {:noreply, renew_interval}

      :error ->
        raise "Unable to fetch mirror statuses"
    end
  end

  def get_mirror_settings() do
    [mirror_selection: {:auto, map}] = :ets.lookup(:cpc_config, :mirror_selection)
    map
  end

  def json_from_remote() do
    # FIXME workaround for buggy dual stack connections. See the comment for
    # Downloader.supports_ip_protocol/2
    address_family =
      case Cpc.Downloader.supports_ipv6(@json_path) do
        true -> :inet6
        false -> :inet
      end

    opts = [
      {:connect_options, [address_family]},
      {:ssl_options, [{:log_alert, false}]},
      []
    ]

    with {:ok, 200, _headers, client} <- :hackney.request(:get, @json_path, [], "", opts) do
      with {:ok, body} <- :hackney.body(client) do
        Jason.decode(body)
      end
    end
  end

  def filter_mirrors(mirrors) do
    settings = get_mirror_settings()

    test_ipv4_protocol = fn url ->
      case settings.ipv4 do
        true -> Cpc.Downloader.supports_ipv4(url)
        false -> true
      end
    end

    test_ipv6_protocol = fn url ->
      case settings.ipv6 do
        true -> Cpc.Downloader.supports_ipv6(url)
        false -> true
      end
    end

    test_protocols = fn url ->
      test_ipv4_protocol.(url) && test_ipv6_protocol.(url)
    end

    test_https = fn protocol ->
      case settings.https_required do
        true -> protocol == "https"
        false -> true
      end
    end

    [mirrors_blacklist: blacklist] = :ets.lookup(:cpc_config, :mirrors_blacklist)
    # test_blacklist = &(!Enum.member?(blacklist, &1))

    test_blacklist = fn url ->
      !Enum.any?(blacklist, fn blacklisted ->
        String.starts_with?(url, blacklisted)
      end)
    end

    for %{"protocol" => protocol, "url" => url, "score" => score} <- mirrors,
        score <= settings.max_score && test_blacklist.(url) && test_https.(protocol) &&
          test_protocols.(url) do
      url
    end
  end

  def fetch_latencies(_url, mirror, i, num_iterations, latencies, _timeout)
      when i == num_iterations do
    {:ok, {mirror, Enum.reduce(latencies, &min/2)}}
  end

  def fetch_latencies(url, mirror, i, num_iterations, latencies, timeout) do
    then = :erlang.timestamp()

    with {:ok, 200, _headers} <- :hackney.request(:head, url, [], "", connect_timeout: timeout) do
      now = :erlang.timestamp()
      diff = :timer.now_diff(now, then)
      fetch_latencies(url, mirror, i + 1, num_iterations, [diff | latencies], timeout)
    end
  end

  def test_mirror(mirror) do
    Logger.debug("test #{inspect(mirror)}")
    url = "#{mirror}core/os/x86_64/core.db"
    settings = get_mirror_settings()
    fetch_latencies(url, mirror, 0, 5, [], settings.timeout)
  end

  def save_mirror_status_to_cache(map = %{}) do
    {:atomic, :ok} =
      :mnesia.transaction(fn ->
        :mnesia.write({MirrorsStatus, "most_recent", {:os.system_time(:second), map}})
      end)

    _ = Logger.debug("Mirrors status saved to cache")
  end

  def sorted_mirrors(json) do
    save_mirror_status_to_cache(json)

    mirrors =
      Enum.filter(json["urls"], fn
        %{"protocol" => "http"} -> true
        %{"protocol" => "https"} -> true
        %{"protocol" => _} -> false
      end)

    results = Enum.map(filter_mirrors(mirrors), fn mirror -> test_mirror(mirror) end)
    successes = for {:ok, {url, latency}} <- results, do: {url, latency}

    Enum.sort_by(successes, fn {_url, latency} -> latency end)
    |> Enum.map(fn {url, _latency} -> url end)
  end
end
