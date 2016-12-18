defmodule Cpc do
  use Application
  require Logger
  @config_path "/etc/cpcache.yaml"

  defp stringmap_to_atom(nil), do: nil
  defp stringmap_to_atom(%{"cache_directory" => cd, "port" => port, "url" => url}), do:
    %{cache_directory: cd, port: port, url: url}

  def init_config() do
    config = YamlElixir.read_from_file(@config_path)
    %{"keep" => keep} = config
    {arm_map, x86_map} = {Map.get(config, "arm"), Map.get(config, "x86")}
    {arm, x86} = {stringmap_to_atom(arm_map), stringmap_to_atom(x86_map)}
    :ets.new(:cpc_config, [:named_table, :protected, read_concurrency: true])
    :ets.insert(:cpc_config, {:keep, keep})
    :ets.insert(:cpc_config, {:arm, arm})
    :ets.insert(:cpc_config, {:x86, x86})
  end

  def start(_type, _args) do
    import Supervisor.Spec, warn: false
    init_config()
    arm_child = case :ets.lookup(:cpc_config, :arm) do
      [arm: nil] -> :not_specified
      [arm: _]   -> {:specified, supervisor(Cpc.Listener, [:arm], id: :arm_listener)}
    end
    x86_child = case :ets.lookup(:cpc_config, :x86) do
      [x86: nil] -> :not_specified
      [x86: _]   -> {:specified, supervisor(Cpc.Listener, [:x86], id: :x86_listener)}
    end
    children = for {:specified, child} <- [arm_child, x86_child], do: child
    Logger.debug "children: #{inspect children}"
    if children == [] do
      raise "At least one architecture must be specified in #{@config_path}: arm or x86."
    end
    opts = [strategy: :one_for_one, name: __MODULE__]
    Supervisor.start_link(children, opts)
  end
end
