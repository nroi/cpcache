defmodule Cpc.Listener do
  use GenServer
  require Logger

  def start_link() do
    GenServer.start_link(__MODULE__, [], strategy: :one_for_one)
  end

  def init([]) do
    [{:port, port}] = :ets.lookup(:cpc_config, :port)

    opts = [
      :binary,
      :inet6,
      active: false,
      reuseaddr: true,
      packet: :http_bin,
      send_timeout: 1000
    ]

    {:ok, listening_sock} = :gen_tcp.listen(port, opts)
    Logger.info("Listening on 127.0.0.1:#{port} and [::1]:#{port}")
    send(self(), :init)
    {:ok, listening_sock}
  end

  def handle_info(:init, listening_sock) do
    accept(listening_sock)
  end

  def accept(listening_sock) do
    _ = Logger.debug("Waiting for a client to accept the connection.")
    {:ok, sock} = :gen_tcp.accept(listening_sock)
    _ = Logger.debug("New connection, start new child.")
    {:ok, child_pid} = Supervisor.start_child(Cpc.ClientRequestSupervisor, [sock])
    # If the socket has already received any messages, they will be safely transferred
    # to the new owner. Note that creating a socket with active mode and then
    # changing the controlling process is supposed to work according to the
    # gen_tcp documentation, but experience shows that this may still cause problems.
    # That is why we chose to start the socket in passive mode, then set active_once.
    :ok = :gen_tcp.controlling_process(sock, child_pid)
    :ok = :inet.setopts(sock, active: :once)
    _ = Logger.debug("Child started, has new socket.")
    accept(listening_sock)
  end
end
