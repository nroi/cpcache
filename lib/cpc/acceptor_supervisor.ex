defmodule Cpc.AcceptorSupervisor do
  import Supervisor.Spec
  use GenServer
  require Logger

  def start_link(listening_sock, mirror, arch, cache_directory, purger_name) do
    {name, serializer} = case arch do
      :x86 -> {:x86_supervisor, :x86_serializer}
      :arm -> {:arm_supervisor, :arm_serializer}
    end
    children = [
      worker(Cpc.Downloader, [mirror, serializer], restart: :temporary)
    ]
    opts = [strategy: :simple_one_for_one]
    {:ok, sup_pid} = Supervisor.start_link(children, opts)
    args = {listening_sock, sup_pid, cache_directory, purger_name}
    GenServer.start_link(__MODULE__, args, name: name)
  end

  def init(init_state) do
    send self(), :init
    {:ok, init_state}
  end

  # Wait for new incoming connection request, then spawn a new child.
  def handle_info(:init, {listening_sock, sup_pid, cache_directory, purger_name}) do
    accept(listening_sock, sup_pid, cache_directory, purger_name)
    {:noreply, nil}
  end

  def accept(listening_sock, sup_pid, cache_directory, purger_name) do
    _ = Logger.debug "Waiting for a client to accept the connection."
    {:ok, accepting_sock} = :gen_tcp.accept(listening_sock)
    _ = Logger.debug "New connection, start new child: #{inspect sup_pid}"
    {:ok, child_pid} = Supervisor.start_child(sup_pid, [accepting_sock, cache_directory, purger_name])
    :ok = :gen_tcp.controlling_process(accepting_sock, child_pid)
    :ok = :inet.setopts(accepting_sock, active: true)
    _ = Logger.debug "Child started, has new socket."
    accept(listening_sock, sup_pid, cache_directory, purger_name)
  end
end
