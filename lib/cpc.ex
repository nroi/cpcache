defmodule Cpc do
  use Application
  require Logger
  @config_path "/etc/cpcache/cpcache.toml"

  defp init_round_robin(config, distro) when distro == :x86 or distro == :arm do
    case config[to_string(distro)] do
      nil -> :ok
      dconfig ->
        num_mirrors = Enum.count(dconfig["mirrors"])
        random = Enum.random(0..num_mirrors - 1)
        :ets.insert(:cpc_round_robin, {distro, {random, num_mirrors}})
    end
  end

  def init_config() do
    config = Jerry.decode!(File.read!(@config_path))
    :ets.new(:cpc_config, [:named_table, :protected, read_concurrency: true])
    :ets.new(:cpc_round_robin, [:named_table, :public])
    :ets.insert(:cpc_config, {:keep, config["keep"]})
    :ets.insert(:cpc_config, {:arm, config["arm"]})
    :ets.insert(:cpc_config, {:x86, config["x86"]})
    :ets.insert(:cpc_config, {:cache_directory, config["cache_directory"]})
    :ets.insert(:cpc_config, {:recv_packages, config["recv_packages"]})
    :ets.insert(:cpc_config, {:ipv6_enabled, config["ipv6_enabled"]})
    init_round_robin(config, :x86)
    init_round_robin(config, :arm)
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
    arm_child = case :ets.lookup(:cpc_config, :arm) do
      [arm: nil] -> :not_specified
      [arm: _]   -> {:specified, supervisor(Cpc.ArchSupervisor, [:arm], id: :arm_supervisor)}
    end
    x86_child = case :ets.lookup(:cpc_config, :x86) do
      [x86: nil] -> :not_specified
      [x86: _]   -> {:specified, supervisor(Cpc.ArchSupervisor, [:x86], id: :x86_supervisor)}
    end
    children = for {:specified, child} <- [arm_child, x86_child], do: child
    if children == [] do
      raise "At least one architecture must be specified in #{@config_path}: arm or x86."
    end
    opts = [strategy: :one_for_one, name: __MODULE__]
    sup = supervisor(Cpc.AcceptorSupervisor, [])
    Supervisor.start_link([sup|children], opts)
  end
end
