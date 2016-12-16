defmodule Cpc.Listener do
  use Supervisor
  require Logger

  def start_link([arch: arch, port: port, mirror: mirror, cache_directory: cache_directory]) do
    Supervisor.start_link(__MODULE__,
                          [arch: arch,
                           port: port,
                           mirror: mirror,
                           cache_directory: cache_directory],
                           strategy: :one_for_one)
  end

  def init([arch: arch, port: port, mirror: mirror, cache_directory: cache_directory]) do
    {:ok, listening_sock} = :gen_tcp.listen(port, [:binary,
                                                   active: false,
                                                   reuseaddr: true,
                                                   packet: :http_bin])
    Logger.info "Listening on port #{port}"
    {serializer_name, acceptor_name, purger_name} = case arch do
      :x86 -> {:x86_serializer, :x86_supervisor, :x86_purger}
      :arm -> {:arm_serializer, :arm_supervisor, :arm_purger}
    end
    children = [
      worker(Cpc.AcceptorSupervisor,
             [listening_sock, mirror, arch, cache_directory, purger_name],
             id: acceptor_name),
      worker(Cpc.Serializer, [serializer_name], id: serializer_name),
      # TODO read from yaml instead of hardcoding value 3
      worker(Cpc.Purger, [cache_directory, 3, purger_name])
    ]
    supervise(children, strategy: :one_for_one)
  end


end
