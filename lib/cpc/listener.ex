defmodule Cpc.Listener do
  use GenServer
  require Logger

  def start_link(dist) when dist == :x86 or dist == :arm do
    GenServer.start_link(__MODULE__, dist, strategy: :one_for_one)
  end

  def init(dist) when dist == :x86 or dist == :arm do
    [{^dist, ets_map}] = :ets.lookup(:cpc_config, dist)
    [{:ipv6_enabled, ipv6_enabled}] = :ets.lookup(:cpc_config, :ipv6_enabled)
    %{"port" => port} = ets_map
    standard_opts = [
      :binary,
      :inet6,
      active: false,
      reuseaddr: true,
      packet: :http_bin,
      send_timeout: 1000
    ]
    opts = case ipv6_enabled do
      true -> [:inet6 | standard_opts]
      false -> standard_opts
    end
    {:ok, listening_sock} = :gen_tcp.listen(port, opts)
    Logger.info "Listening on port #{port}"
    send self(), :init
    {:ok, {dist, listening_sock}}
  end

  def handle_info(:init, {dist, listening_sock}) do
    accept(dist, listening_sock)
  end

  def accept(dist, listening_sock) do
    _ = Logger.debug "Waiting for a client to accept the connection."
    {:ok, sock} = :gen_tcp.accept(listening_sock)
    _ = Logger.debug "New connection, start new child."
    {:ok, child_pid} = Supervisor.start_child(Cpc.AcceptorSupervisor, [dist, sock])
    # If the socket has already received any messages, they will be safely transferred
    # to the new owner. Note that creating a socket with active mode and then
    # changing the controlling process is supposed to work according to the
    # gen_tcp documentation, but experience shows that this may still cause problems.
    :ok = :gen_tcp.controlling_process(sock, child_pid)
    :ok = :inet.setopts(sock, active: :once)
    _ = Logger.debug "Child started, has new socket."
    accept(dist, listening_sock)
  end


end
