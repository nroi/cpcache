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
    {serializer_name, acceptor_name} = case arch do
      :x86 -> {:x86_serializer, :x86_supervisor}
      :arm -> {:arm_serializer, :arm_supervisor}
    end
    children = [
      worker(Cpc.AcceptorSupervisor,
             [listening_sock, mirror, arch, cache_directory],
             id: acceptor_name),
      worker(Cpc.Serializer, [serializer_name], id: serializer_name),
    ]
    supervise(children, strategy: :one_for_one)
  end


end
