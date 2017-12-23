defmodule Cpc.MirrorSelector do
  use GenServer
  require Logger
  @json_path "https://www.archlinux.org/mirrors/status/json/"
  @retry_after 5000

  def start_link() do
    [mirrors: predefined] = :ets.lookup(:cpc_config, :mirrors)
    state = {{:sorted, []}, {:predefined, predefined}}
    GenServer.start_link(__MODULE__, state, name: __MODULE__)
  end

  def init(state) do
    send self(), :init
    {:ok, state}
  end

  defp get_from(mirrors, n) do
    case Enum.at(mirrors, n) do
      nil -> {:error, "No further mirrors"}
      mirror -> {:ok, mirror}
    end
  end


  def get(n) when is_number(n) do
    GenServer.call(__MODULE__, {:get, n})
  end

  def handle_call({:get, _}, _from, state = {{:sorted, []}, {:predefined, []}}) do
    {:reply, {:error, "No mirrors available"}, state}
  end

  def handle_call({:get, n}, _from, state = {{:sorted, sorted = [_|_]}, {:predefined, _}}) do
    {:reply, get_from(sorted, n), state}
  end

  def handle_call({:get, n}, _from, state = {{:sorted, []}, {:predefined, predef = [_|_]}}) do
    {:reply, get_from(predef, n), state}
  end

  def handle_info(:init, {{:sorted, []}, {:predefined, predefined}}) do
    case sorted_mirrors() do
      {:ok, sorted} ->
        :ets.insert(:cpc_state, {:mirrors, sorted})
        Logger.debug "Mirrors sorted: #{inspect sorted}"
        {:noreply, {{:sorted, sorted}, {:predefined, predefined}}}
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
    for %{"protocol" => "https", "url" => url, "score" => score} <- mirrors, score < 2.5, do: url
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
