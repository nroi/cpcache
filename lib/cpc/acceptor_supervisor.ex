defmodule Cpc.AcceptorSupervisor do
  import Supervisor.Spec
  use GenServer
  require Logger

  def start_link(listening_sock, mirror, arch, cache_directory) do
    {name, serializer} = case arch do
      :x86 -> {:x86_supervisor, :x86_serializer}
      :arm -> {:arm_supervisor, :arm_serializer}
    end
    children = [
      worker(Cpc.Downloader, [mirror, serializer], restart: :transient, max_restarts: 0)
    ]
    opts = [strategy: :simple_one_for_one]
    {:ok, sup_pid} = Supervisor.start_link(children, opts)
    Logger.info "sup with pid: #{inspect sup_pid}"
    # Process.register(sup_pid, :download_supervisor)
    GenServer.start_link(__MODULE__,
                         {listening_sock, sup_pid, cache_directory},
                         name: name)
  end

  def init(listening_sock) do
    send self(), :init
    {:ok, listening_sock}
  end

  # Wait for new incoming connection request, then spawn a new child.
  def handle_info(:init, {listening_sock, sup_pid, cache_directory}) do
    accept(listening_sock, sup_pid, cache_directory)
    {:noreply, nil}
  end

  def accept(listening_sock, sup_pid, cache_directory) do
    _ = Logger.debug "Waiting for a client to accept the connection."
    {:ok, accepting_sock} = :gen_tcp.accept(listening_sock)
    _ = Logger.debug "New connection, start new child: #{inspect sup_pid}"
    {:ok, child_pid} = Supervisor.start_child(sup_pid, [accepting_sock, cache_directory])
    :ok = :gen_tcp.controlling_process(accepting_sock, child_pid)
    :ok = :inet.setopts(accepting_sock, active: true)
    _ = Logger.debug "child started, has new socket."
    accept(listening_sock, sup_pid, cache_directory)
  end
end
