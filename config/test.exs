import Config

config :chat,
  http_port: 4001,
  tcp_port: 4041,
  room_idle_timeout: 100

config :logger, level: :warning
