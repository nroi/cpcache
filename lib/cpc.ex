defmodule Cpc do
  use Application
  require Logger

  # See http://elixir-lang.org/docs/stable/elixir/Application.html
  # for more information on OTP Applications
  def start(_type, _args) do
    import Supervisor.Spec, warn: false

    # values are loaded once from file in /etc, so that settings are fixed after program startup.
    [cpc: proplist] = Mix.Config.read!("/etc/cpc.exs")
    Enum.each(proplist, fn {key, value} -> Application.put_env(:cpc, key, value) end)

    port = Application.get_env(:cpc, :port)
    {:ok, listening_sock} = :gen_tcp.listen(port, [:binary, reuseaddr: true, packet: :line])
    Logger.info "listening on #{port}"

    # Define workers and child supervisors to be supervised
    children = [
      # Starts a worker by calling: Cpc.Worker.start_link(arg1, arg2, arg3)
      worker(Cpc.AcceptorSupervisor, [listening_sock]),
      worker(Cpc.Serializer, []),
    ]

    # See http://elixir-lang.org/docs/stable/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Cpc.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
