defmodule Cpc do
  use Application
  require Logger
  @config_path "/etc/cpcache/cpcache.toml"

  defp init_round_robin(config) do
    num_mirrors = Enum.count(config["mirrors"])
    random = Enum.random(0..num_mirrors - 1)
    :ets.insert(:cpc_state, {:round_robin, {random, num_mirrors}})
  end

  def init_config() do
    config = Jerry.decode!(File.read!(@config_path))
    :ets.new(:cpc_config, [:named_table, :protected, read_concurrency: true])
    :ets.new(:cpc_state, [:named_table, :public])
    :ets.insert(:cpc_config, {:port, config["port"]})
    :ets.insert(:cpc_config, {:cache_directory, config["cache_directory"]})
    :ets.insert(:cpc_config, {:recv_packages, config["recv_packages"]})
    :ets.insert(:cpc_config, {:ipv6_enabled, config["ipv6_enabled"]})
    :ets.insert(:cpc_config, {:mirrors, config["mirrors"]})
    # TODO are we actually using that option anywhere?
    :ets.insert(:cpc_config, {:ipv6_enforced, config["ipv6_enforced"]})
    init_round_robin(config)
  end

  def create_table(table, options) do
    if not Enum.member?(:mnesia.system_info(:tables), table) do
      _ = Logger.info "Table #{table} does not exist, will create it."
      :stopped = :mnesia.stop()
      case :mnesia.create_schema([node()]) do
        :ok ->
          _ = Logger.debug "Successfully created schema for mnesia."
        {:error, {_, {:already_exists, _}}} ->
          _ = Logger.debug "Mnesia schema already exists."
      end
      :ok = :mnesia.start()
      case :mnesia.create_table(table, options) do
        {:atomic, :ok} ->
          _ = Logger.debug "Successfully created Mnesia table."
        {:aborted, {:already_exists, ^table}} ->
          _ = Logger.debug "Mnesia table already exists."
      end
    end
  end

  def init_mnesia() do
    options_downloadspeed = [attributes: [:url, :content_length, :start_time, :diff_time],
                             disc_copies: [node()],
                             type: :bag
    ]
    create_table(DownloadSpeed, options_downloadspeed)
    create_table(ContentLength, [attributes: [:path, :content_length], disc_copies: [node()]])
    create_table(Ipv6Support, [attributes: [:date, :supported]])
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
