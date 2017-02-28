defmodule Cpc.Listener do
  use GenServer
  require Logger

  def start_link(arch) when arch == :x86 or arch == :arm do
    GenServer.start_link(__MODULE__, arch, strategy: :one_for_one)
  end

  def init(arch) when arch == :x86 or arch == :arm do
    [{^arch, ets_map}] = :ets.lookup(:cpc_config, arch)
    %{port: port} = ets_map
    {:ok, listening_sock} = :gen_tcp.listen(port, [:binary,
                                                   active: false,
                                                   reuseaddr: true,
                                                   packet: :http_bin,
                                                   send_timeout: 1000
                                                 ])
    Logger.info "Listening on port #{port}"
    send self(), :init
    {:ok, {arch, listening_sock}}
  end

  def handle_info(:init, {arch, listening_sock}) do
    accept(arch, listening_sock)
  end

  def accept(arch, listening_sock) do
    _ = Logger.debug "Waiting for a client to accept the connection."
    {:ok, sock} = :gen_tcp.accept(listening_sock)
    _ = Logger.debug "New connection, start new child."
    {:ok, child_pid} = Supervisor.start_child(Cpc.AcceptorSupervisor, [arch, sock])
    # If the socket has already received any messages, they will be safely transferred
    # to the new owner. Note that creating a socket with active mode and then
    # changing the controlling process is supposed to work according to the
    # gen_tcp documentation, but experience shows that this may still cause problems.
    :ok = :gen_tcp.controlling_process(sock, child_pid)
    :ok = :inet.setopts(sock, active: :once)
    _ = Logger.debug "Child started, has new socket."
    accept(arch, listening_sock)
  end


end
