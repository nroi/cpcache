defmodule Cpc do
  use Application
  require Logger

  # See http://elixir-lang.org/docs/stable/elixir/Application.html
  # for more information on OTP Applications
  def start(_type, _args) do
    import Supervisor.Spec, warn: false

    # values are loaded once from file in /etc, so that settings are fixed after program startup.
    config = YamlElixir.read_from_file("/etc/cpc.yaml")
    arm_config = case config["arm"] do
      nil -> nil
      c -> {:arm_listener, [arch: :arm,
                            port: c["port"],
                            mirror: c["url"],
                            cache_directory: c["cache_directory"]]}
    end
    x86_config = case config["x86"] do
      nil -> nil
      c -> {:x86_listener, [arch: :x86,
                            port: c["port"],
                            mirror: c["url"],
                            cache_directory: c["cache_directory"]]}
    end

    arch_configs = Enum.filter([arm_config, x86_config], &(&1 != nil))

    children = Enum.map(arch_configs, fn {name, opts} ->
      supervisor(Cpc.Listener, [opts], name: name, id: name)
    end)


    # See http://elixir-lang.org/docs/stable/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: __MODULE__]
    Supervisor.start_link(children, opts)
  end
end
