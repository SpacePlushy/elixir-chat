import Config

config :chat,
  http_port: 4000,
  tcp_port: 4040,
  room_idle_timeout: :timer.minutes(5)

import_config "#{config_env()}.exs"
