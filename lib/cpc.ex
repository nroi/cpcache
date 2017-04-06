defmodule Cpc do
  use Application
  require Logger
  @config_path "/etc/cpcache/cpcache.yaml"

  defp stringmap_to_atom(nil), do: nil
  defp stringmap_to_atom(%{"port" => port, "url" => url}), do: %{port: port, url: url}

  def init_config() do
    config = YamlElixir.read_from_file(@config_path)
    %{"keep" => keep} = config
    %{"cache_directory" => cache_directory} = config
    recv_packages = config["recv_packages"]
    {arm_map, x86_map} = {Map.get(config, "arm"), Map.get(config, "x86")}
    {arm, x86} = {stringmap_to_atom(arm_map), stringmap_to_atom(x86_map)}
    :ets.new(:cpc_config, [:named_table, :protected, read_concurrency: true])
    :ets.insert(:cpc_config, {:keep, keep})
    :ets.insert(:cpc_config, {:arm, arm})
    :ets.insert(:cpc_config, {:x86, x86})
    :ets.insert(:cpc_config, {:cache_directory, cache_directory})
    :ets.insert(:cpc_config, {:recv_packages, recv_packages})
  end

  def init_mnesia() do
    if not Enum.member?(:mnesia.system_info(:tables), ContentLength) do
      _ = Logger.info "Table ContentLength does not exist, will create it."
      :stopped = :mnesia.stop()
      case :mnesia.create_schema([node()]) do
        :ok ->
          _ = Logger.debug "Successfully created schema for mnesia."
        {:error, {_, {:already_exists, _}}} ->
          _ = Logger.debug "Mnesia schema already exists."
      end
      :ok = :mnesia.start()
      options = [attributes: [:path, :content_length], disc_copies: [node()]]
      case :mnesia.create_table(ContentLength, options) do
        {:atomic, :ok} ->
          _ = Logger.debug "Successfully created Mnesia table."
        {:aborted, {:already_exists, ContentLength}} ->
          _ = Logger.debug "Mnesia table already exists."
      end
    end
    if not Enum.member?(:mnesia.system_info(:tables), DownloadSpeed) do
      _ = Logger.info "Mnesia table does not exist, will create it."
      :stopped = :mnesia.stop()
      case :mnesia.create_schema([node()]) do
        :ok ->
          _ = Logger.debug "Successfully created schema for mnesia."
        {:error, {_, {:already_exists, _}}} ->
          _ = Logger.debug "Mnesia schema already exists."
      end
      :ok = :mnesia.start()
      options = [attributes: [:url, :content_length, :start_time, :end_time],
                 disc_copies: [node()],
                 type: :bag
                ]
      case :mnesia.create_table(DownloadSpeed, options) do
        {:atomic, :ok} ->
          _ = Logger.debug "Successfully created Mnesia table."
        {:aborted, {:already_exists, DownloadSpeed}} ->
          _ = Logger.debug "Mnesia table already exists."
      end
    end
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
