defmodule Cpc.MirrorSelector do
  use GenServer
  alias Cpc.TableAccess
  alias Cpc.Downloader
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

  @impl true
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
          _ = Logger.debug("Run new latency tests after #{hours} hours have expired.")
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
    # Instead of fetching the mirrors directly from :ets, we use message passing.
    # This ensures that the mirror selection process (e.g., running latency tests etc.) has already completed
    # when the result is returned.
    GenServer.call(__MODULE__, :get_all)
  end

  def get_json(num_attempts) when num_attempts == @max_attempts do
    # failed to fetch the most recent mirror status from remote: see if we can fetch an older
    # version from cache.
    _ =
      Logger.warn(
        "Max. number of attempts exceeded. Checking for a cached version of " <>
          "the mirror data…"
      )

    db_result = TableAccess.get("mirrors_status", "most_recent")

    case db_result do
      {:ok, {_timestamp, map}} ->
        {:ok, map}

      {:error, :not_found} ->
        _ = Logger.warn("No mirror data found in cache.")
        :error
    end
  end

  def get_json(num_attempts) when num_attempts < @max_attempts do
    case json_from_remote() do
      result = {:ok, _json} ->
        Logger.info("Successfully fetched mirror data from #{@json_path}.")
        result

      other ->
        Logger.warn("Unable to fetch mirror data from #{@json_path}: #{inspect(other)}")
        Logger.warn("Retry in #{@retry_after} milliseconds")
        :timer.sleep(@retry_after)
        get_json(num_attempts + 1)
    end
  end

  @impl true
  def handle_call(:get_all, _from, state) do
    # TODO is there any good reason left to use :ets now that we use message passing?
    # We might as well just save the mirrors in the state.
    [mirrors: mirrors] = :ets.lookup(:cpc_state, :mirrors)
    {:reply, mirrors, state}
  end

  @impl true
  def handle_info(:init, renew_interval) do
    case get_json(0) do
      {:ok, map} ->
        sorted = sorted_mirrors(map)
        [mirrors: predefined] = :ets.lookup(:cpc_config, :mirrors)
        :ets.insert(:cpc_state, {:mirrors, sorted ++ predefined})
        Logger.debug("The following mirror list will be used: #{inspect(sorted)}")

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

  @impl true
  def handle_info({:ssl_closed, {:sslsocket, _, _}}, state) do
    # TODO need to find out where this message originates from.
    # Could be due to a bug in hackney: https://github.com/benoitc/hackney/issues/464
    # We should be able to remove this clause if we switch from hackney to mint.
    {:noreply, state}
  end

  def get_mirror_settings() do
    [mirror_selection: {:auto, map}] = :ets.lookup(:cpc_config, :mirror_selection)
    map
  end

  def json_from_remote() do
    # TODO use eyepatch
    with {:ok, 200, _headers, client} <- :hackney.request(:get, @json_path, [], "", []) do
      with {:ok, body} <- :hackney.body(client) do
        Jason.decode(body)
      end
    end
  end

  def filter_mirrors(mirrors) do
    settings = get_mirror_settings()

    test_https = fn protocol ->
      case settings.https_required do
        true -> protocol == "https"
        false -> true
      end
    end

    [mirrors_blacklist: blacklist] = :ets.lookup(:cpc_config, :mirrors_blacklist)

    test_blacklist = fn url ->
      !Enum.any?(blacklist, fn blacklisted ->
        String.starts_with?(url, blacklisted)
      end)
    end

    sorter =
      case settings.mirrors_random_or_sort do
        "random" -> &Enum.shuffle(&1)
        "sort" -> &Enum.sort_by(&1, fn %{"score" => score} -> score end)
      end

    for %{"protocol" => protocol, "url" => url, "score" => score} <- sorter.(mirrors),
        score <= settings.max_score && test_blacklist.(url) && test_https.(protocol) do
      url
    end
  end

  def hackney_head_dual_stack(url, timeout) do
    # TODO make use of the timeout.
    with {:ok, {_protocol, conn_ref}} <- Downloader.hackney_connect_dual_stack(url) do
      req = {:head, "/", [], ""}

      with {:ok, status, _headers} <- :hackney.send_request(conn_ref, req) do
        {:ok, status}
      end
    end
  end

  def fetch_latencies(_url, mirror, i, num_iterations, latencies, _timeout)
      when i == num_iterations do
    {:ok, {mirror, Enum.reduce(latencies, &min/2)}}
  end

  def fetch_latencies(url, mirror, i, num_iterations, latencies, timeout) do
    then = :erlang.timestamp()

    with {:ok, _result} <- hackney_head_dual_stack(url, timeout) do
      now = :erlang.timestamp()
      diff = :timer.now_diff(now, then)
      fetch_latencies(url, mirror, i + 1, num_iterations, [diff | latencies], timeout)
    end
  end

  def test_mirror(mirror) do
    Logger.debug("Run latency test for: #{inspect(mirror)}")
    url = "#{mirror}core/os/x86_64/core.db"
    settings = get_mirror_settings()
    fetch_latencies(url, mirror, 0, 5, [], settings.timeout)
  end

  def save_mirror_status_to_cache(map = %{}) do
    TableAccess.add("mirrors_status", "most_recent", {:os.system_time(:second), map})
    _ = Logger.debug("Mirrors status saved to cache")
  end

  def sorted_mirrors(json) do
    save_mirror_status_to_cache(json)
    settings = get_mirror_settings()

    mirrors =
      Enum.filter(json["urls"], fn
        %{"protocol" => "http"} -> true
        %{"protocol" => "https"} -> true
        %{"protocol" => _} -> false
      end)

    results =
      mirrors
      |> filter_mirrors
      |> Enum.take(settings.num_mirrors)
      |> Enum.map(&test_mirror/1)

    successes = for {:ok, {url, latency}} <- results, do: {url, latency}

    successes
    |> Enum.sort_by(fn {_url, latency} -> latency end)
    |> Enum.map(fn {url, _latency} -> url end)
  end
end
