defmodule Cpc.Mixfile do
  use Mix.Project

  def project do
    [
      elixirc_paths: elixirc_paths(Mix.env()),
      app: :cpcache,
      version: "0.1.0",
      elixir: "~> 1.8",
      build_embedded: Mix.env() == :prod,
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  # Configuration for the OTP application
  #
  # Type "mix help compile.app" for more information
  def application do
    [applications: [:logger, :inets, :ssl, :hackney, :toml, :jason, :eyepatch], mod: {Cpc, []}]
  end

  # Dependencies can be Hex packages:
  #
  #   {:mydep, "~> 0.3.0"}
  #
  # Or git/path repositories:
  #
  #   {:mydep, git: "https://github.com/elixir-lang/mydep.git", tag: "0.1.0"}
  #
  # Type "mix help deps" for more examples and options
  defp deps do
    [
      {:distillery, "~> 2.0"},
      {:hackney, "~> 1.15"},
      {:toml, "~> 0.5.2"},
      {:jason, "~> 1.1"},
      {:eyepatch, git: "https://github.com/nroi/eyepatch.git", tag: "v0.1.11"}
    ]
  end
end
