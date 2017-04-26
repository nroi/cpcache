defmodule Cpc.ArchSupervisor do
  use Supervisor
  require Logger

  def start_link(distro) when distro == :x86 or distro == :arm do
    Supervisor.start_link(__MODULE__, distro, strategy: :one_for_one)
  end

  def init(distro) when distro == :x86 or distro == :arm do
    cache_directory = Cpc.Utils.cache_dir_from_distro(distro)
    case File.mkdir(cache_directory) do
      {:error, :eexist} -> :ok
      :ok -> :ok
    end
    [{:keep, keep}] = :ets.lookup(:cpc_config, :keep)
    {serializer_name, listener_name, purger_name} = case distro do
      :x86 -> {:x86_serializer, :x86_listener, :x86_purger}
      :arm -> {:arm_serializer, :arm_listener, :arm_purger}
    end
    children = case keep do
      0 ->
        [worker(Cpc.Serializer, [serializer_name], id: serializer_name),
         worker(Cpc.Listener, [distro], id: listener_name)]
      k ->
        [worker(Cpc.Serializer, [serializer_name], id: serializer_name),
         worker(Cpc.Purger, [cache_directory, k, purger_name]),
         worker(Cpc.Listener, [distro], id: listener_name)]
    end
    supervise(children, strategy: :one_for_one)
  end

end
