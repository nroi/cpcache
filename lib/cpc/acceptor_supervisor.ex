defmodule Cpc.AcceptorSupervisor do
  import Supervisor.Spec
  use GenServer
  require Logger

  def start_link(listening_sock) do
    children = [
      worker(Cpc.Downloader, [], restart: :transient, max_restarts: 0)
    ]
    opts = [strategy: :simple_one_for_one]
    {:ok, sup_pid} = Supervisor.start_link(children, opts)
    Process.register(sup_pid, :download_supervisor)
    GenServer.start_link(__MODULE__, listening_sock, name: __MODULE__)
  end

  def init(listening_sock) do
    send self(), :init
    {:ok, listening_sock}
  end

  # Wait for new incoming connection request, then spawn a new child.
  def handle_info(:init, listening_sock) do
    {:ok, _} = Task.start_link(fn ->
      accept(listening_sock)
    end)
    {:noreply, nil}
  end

  def accept(listening_sock) do
    _ = Logger.info "Waiting for a client to accept the connection."
    {:ok, accepting_sock} = :gen_tcp.accept(listening_sock)
    _ = Logger.debug "new connection, start new child."
    {:ok, child_pid} = Supervisor.start_child(:download_supervisor, [[accepting_sock], []])
    :ok = :gen_tcp.controlling_process(accepting_sock, child_pid)
    :ok = :inet.setopts(accepting_sock, active: true)
    _ = Logger.debug "child started, has new socket."
    accept(listening_sock)
  end
end
