import Config

# Hosts like Render tell the app which port to listen on through $PORT.
if port = System.get_env("PORT") do
  config :chat, http_port: String.to_integer(port)
end

if port = System.get_env("TCP_PORT") do
  config :chat, tcp_port: String.to_integer(port)
end
