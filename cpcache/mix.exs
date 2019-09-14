defmodule Cpc.Mixfile do
  use Mix.Project

  def project do
    [
      elixirc_paths: elixirc_paths(Mix.env()),
      app: :cpcache,
      version: "0.1.0",
      elixir: "~> 1.9",
      build_embedded: Mix.env() == :prod,
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  def application do
    [
      applications: [:logger, :inets, :ssl, :hackney, :toml, :jason, :eyepatch, :morbo],
      mod: {Cpc, []}
    ]
  end

  defp deps do
    [
      {:hackney, "~> 1.15"},
      {:toml, "~> 0.5.2"},
      {:jason, "~> 1.1"},
      {:eyepatch, git: "https://github.com/nroi/eyepatch.git", tag: "v0.1.12"},
      {:morbo, git: "https://github.com/nroi/morbo.git", tag: "0.1.3"}
    ]
  end
end
