defmodule Cpc do
  use Application
  require Logger
  @config_path "/etc/cpcache/cpcache.toml"

  defp init_round_robin(config) do
    num_mirrors = Enum.count(get_or_raise(config, "mirrors_predefined"))
    random = Enum.random(0..(num_mirrors - 1))
    :ets.insert(:cpc_state, {:round_robin, {random, num_mirrors}})
  end

  def get_or_raise(map = %{}, key) do
    case Map.get(map, key) do
      nil ->
        raise "Unable to fetch key #{inspect(key)}. Please make sure the TOML file " <>
                "#{inspect(@config_path)} contains all required keys."

      value ->
        value
    end
  end

  def init_config() do
    config = Jerry.decode!(File.read!(@config_path))
    :ets.new(:cpc_config, [:named_table, :protected, read_concurrency: true])
    :ets.new(:cpc_state, [:named_table, :public])
    :ets.insert(:cpc_config, {:port, get_or_raise(config, "port")})
    :ets.insert(:cpc_config, {:cache_directory, get_or_raise(config, "cache_directory")})
    :ets.insert(:cpc_config, {:recv_packages, get_or_raise(config, "recv_packages")})
    :ets.insert(:cpc_config, {:ipv6_enabled, get_or_raise(config, "ipv6_enabled")})
    :ets.insert(:cpc_config, {:mirrors, get_or_raise(config, "mirrors_predefined")})
    :ets.insert(:cpc_config, {:mirrors_blacklist, get_or_raise(config, "mirrors_blacklist")})

    case get_or_raise(config, "mirror_selection_method") do
      "auto" ->
        mirrors_auto = get_or_raise(config, "mirrors_auto")

        map = %{
          https_required: get_or_raise(mirrors_auto, "https_required"),
          ipv4: get_or_raise(mirrors_auto, "ipv4"),
          ipv6: get_or_raise(mirrors_auto, "ipv6"),
          max_score: get_or_raise(mirrors_auto, "max_score"),
          timeout: get_or_raise(mirrors_auto, "timeout"),
          test_interval: get_or_raise(mirrors_auto, "test_interval")
        }

        :ets.insert(:cpc_config, {:mirror_selection, {:auto, map}})

      "predefined" ->
        :ok
    end

    init_round_robin(config)
  end

  def create_table(table, options) do
    if not Enum.member?(:mnesia.system_info(:tables), table) do
      _ = Logger.info("Table #{table} does not exist, will create it.")
      :stopped = :mnesia.stop()

      case :mnesia.create_schema([node()]) do
        :ok ->
          _ = Logger.debug("Successfully created schema for mnesia.")

        {:error, {_, {:already_exists, _}}} ->
          _ = Logger.debug("Mnesia schema already exists.")
      end

      :ok = :mnesia.start()

      case :mnesia.create_table(table, options) do
        {:atomic, :ok} ->
          _ = Logger.debug("Successfully created Mnesia table.")

        {:aborted, {:already_exists, ^table}} ->
          _ = Logger.debug("Mnesia table already exists.")
      end
    end
  end

  def init_mnesia() do
    options_downloadspeed = [
      attributes: [:url, :content_length, :start_time, :diff_time],
      disc_copies: [node()],
      type: :bag
    ]

    create_table(ContentLength, attributes: [:path, :content_length], disc_copies: [node()])
    create_table(Ipv6Support, attributes: [:date, :supported], disc_copies: [node()])
    create_table(Ipv4Support, attributes: [:date, :supported], disc_copies: [node()])
    create_table(MirrorsStatus, attributes: [:date, :status], disc_copies: [node()])
  end

  def start(_type, _args) do
    import Supervisor.Spec, warn: false
    init_config()
    init_mnesia()

    children = [
      supervisor(Cpc.ArchSupervisor, []),
      supervisor(Cpc.AcceptorSupervisor, [])
    ]

    opts = [strategy: :one_for_one, name: __MODULE__]
    Supervisor.start_link(children, opts)
  end
end
