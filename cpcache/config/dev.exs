use Mix.Config

config :logger, :console, metadata: [:pid]

config :cpcache,
  throttle_downloads: true
