defmodule Cpc.Listener do
  use Supervisor
  require Logger

  def start_link(arch) do
    Supervisor.start_link(__MODULE__, [arch: arch], strategy: :one_for_one)
  end

  def init([arch: arch]) do
    [{^arch, ets_map}] = :ets.lookup(:cpc_config, arch)
    %{port: port, cache_directory: cache_directory} = ets_map
    [{:keep, keep}] = :ets.lookup(:cpc_config, :keep)
    {:ok, listening_sock} = :gen_tcp.listen(port, [:binary,
                                                   active: false,
                                                   reuseaddr: true,
                                                   packet: :http_bin])
    Logger.info "Listening on port #{port}"
    {serializer_name, acceptor_name, purger_name} = case arch do
      :x86 -> {:x86_serializer, :x86_supervisor, :x86_purger}
      :arm -> {:arm_serializer, :arm_supervisor, :arm_purger}
    end
    children = case keep do
      0 ->
        [worker(Cpc.AcceptorSupervisor, [listening_sock, arch, purger_name], id: acceptor_name),
         worker(Cpc.Serializer, [serializer_name], id: serializer_name)]
      k ->
        [worker(Cpc.AcceptorSupervisor, [listening_sock, arch, purger_name], id: acceptor_name),
         worker(Cpc.Serializer, [serializer_name], id: serializer_name),
         worker(Cpc.Purger, [cache_directory, k, purger_name])]
    end
    supervise(children, strategy: :one_for_one)
  end


end
