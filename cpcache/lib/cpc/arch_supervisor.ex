defmodule Cpc.ArchSupervisor do
  use Supervisor
  require Logger

  def start_link() do
    Supervisor.start_link(__MODULE__, [], strategy: :one_for_one)
  end

  def init([]) do
    cache_directory =
      case :ets.lookup(:cpc_config, :cache_directory) do
        [{:cache_directory, cdir}] ->
          Path.join(cdir, "pkg")
      end

    case File.mkdir(cache_directory) do
      {:error, :eexist} -> :ok
      :ok -> :ok
    end

    children = [
      worker(Cpc.Serializer, []),
      worker(Cpc.Listener, []),
      worker(Cpc.MirrorSelector, [])
    ]

    supervise(children, strategy: :one_for_one)
  end
end
