defmodule Cpc.ArchSupervisor do
  use Supervisor
  require Logger

  def start_link(arch) when arch == :x86 or arch == :arm do
    Supervisor.start_link(__MODULE__, arch, strategy: :one_for_one)
  end

  def init(arch) when arch == :x86 or arch == :arm do
    [{^arch, ets_map}] = :ets.lookup(:cpc_config, arch)
    %{cache_directory: cache_directory} = ets_map
    [{:keep, keep}] = :ets.lookup(:cpc_config, :keep)
    {serializer_name, listener_name, purger_name} = case arch do
      :x86 -> {:x86_serializer, :x86_listener, :x86_purger}
      :arm -> {:arm_serializer, :arm_listener, :arm_purger}
    end
    children = case keep do
      0 ->
        [worker(Cpc.Serializer, [serializer_name], id: serializer_name),
         worker(Cpc.Listener, [arch], id: listener_name)]
      k ->
        [worker(Cpc.Serializer, [serializer_name], id: serializer_name),
         worker(Cpc.Purger, [cache_directory, k, purger_name]),
         worker(Cpc.Listener, [arch], id: listener_name)]
    end
    supervise(children, strategy: :one_for_one)
  end

end
