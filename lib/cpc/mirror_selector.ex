defmodule Cpc.MirrorSelector do
  use GenServer
  require Logger
  @json_path "https://www.archlinux.org/mirrors/status/json/"
  @retry_after 5000

  # The module used to test the latency of all available mirrors in order to sort them and provide a
  # selection of low-latency mirrors.

  def start_link() do
    GenServer.start_link(__MODULE__, nil, name: __MODULE__)
  end

  def init(nil) do
    # Start with the predefined mirrors. We will add "better" mirrors later, but for now, we want to
    # have some mirrors available in case a mirror is requested before the process to find the best
    # mirrors has completed.
    [mirrors: predefined] = :ets.lookup(:cpc_config, :mirrors)
    renew_interval = case :ets.lookup(:cpc_config, :mirror_selection) do
      [mirror_selection: {:auto, %{test_interval: -1}}] ->
        :never
      [mirror_selection: {:auto, %{test_interval: hours}}] when is_number(hours) ->
        _ = Logger.debug "Run new test after #{hours} hours have expired."
        hours * 60 * 60 * 1000
      _ ->
        :never
    end
    :ets.insert(:cpc_state, {:mirrors, predefined})
    send self(), :init
    {:ok, renew_interval}
  end

  def get(n) when is_integer(n) do
    # TODO reconsider if we still need this function, or if we should always use get_all
    # since we have introduced the Cpc.Downloader.try_all function.
    [mirrors: mirrors] = :ets.lookup(:cpc_state, :mirrors)
    case Enum.at(mirrors, n) do
      nil -> {:error, "No further mirrors"}
      mirror -> {:ok, mirror}
    end
  end

  def get_all() do
    [mirrors: mirrors] = :ets.lookup(:cpc_state, :mirrors)
    mirrors
  end

  def handle_info(:init, renew_interval) do
    case sorted_mirrors() do
      {:ok, sorted} ->
        [mirrors: predefined] = :ets.lookup(:cpc_config, :mirrors)
        :ets.insert(:cpc_state, {:mirrors, sorted ++ predefined})
        Logger.debug "Mirrors sorted: #{inspect sorted}"
        case renew_interval do
          :never -> :ok
          millisecs when is_integer(millisecs) ->
            :erlang.send_after(millisecs, self(), :init)
        end
        {:noreply, renew_interval}
      error ->
        Logger.warn "Unable to sort mirrors: #{inspect error}"
        Logger.warn "Retry in #{@retry_after} milliseconds"
        :erlang.send_after(@retry_after, self(), :init)
    end
  end

  def get_settings() do
    [mirror_selection: {:auto, map}] = :ets.lookup(:cpc_config, :mirror_selection)
    map
  end

  def json_from_remote() do
    opts = [
      {:connect_options, []},
      {:ssl_options, [{:log_alert, false}]},
        []
      ]
    with {:ok, 200, _headers, client} <- :hackney.request(:get, @json_path, [], "", opts) do
      with {:ok, body} <- :hackney.body(client) do
        Poison.decode(body)
      end
    end
  end

  def filter_mirrors(mirrors) do
    # TODO make use of the settings from the TOML file.
    for %{"protocol" => "https", "url" => url, "score" => score} <- mirrors, score < 2.5 && Cpc.Downloader.supports_ipv6(url) do
      url
    end
  end

  def fetch_latencies(_url, mirror, i, num_iterations, latencies, _timeout) when i == num_iterations do
    {:ok, {mirror, Enum.reduce(latencies, &min/2)}}
  end
  def fetch_latencies(url, mirror, i, num_iterations, latencies, timeout) do
    then = :erlang.timestamp()
    with {:ok, 200, _headers} <- :hackney.request(:head, url, [], "", connect_timeout: timeout) do
      now = :erlang.timestamp()
      diff = :timer.now_diff(now, then)
      fetch_latencies(url, mirror, i+1, num_iterations, [diff | latencies], timeout)
    end
  end

  def test_mirror(mirror) do
    Logger.debug "test #{inspect mirror}"
    url = "#{mirror}core/os/x86_64/core.db"
    settings = get_settings()
    fetch_latencies(url, mirror, 0, 5, [], settings.timeout)
  end

  def sorted_mirrors() do
    with {:ok, json} <- json_from_remote() do
      mirrors = json["urls"]
      results = Enum.map(filter_mirrors(mirrors), fn mirror -> test_mirror(mirror) end)
      successes = for {:ok, {url, latency}} <- results, do: {url, latency}
      sorted = Enum.sort_by(successes, fn
        {_url, latency} -> latency
      end) |> Enum.map(fn
        {url, _latency} -> url
      end)
      {:ok, sorted}
    end
  end


end
