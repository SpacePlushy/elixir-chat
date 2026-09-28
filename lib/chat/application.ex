defmodule Chat.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      # Rooms: found by name in the Registry, started on demand under the supervisor.
      {Registry, keys: :unique, name: Chat.RoomRegistry},
      {DynamicSupervisor, name: Chat.RoomSupervisor, strategy: :one_for_one},

      # Telnet: one supervised process per connection, plus the acceptor.
      {DynamicSupervisor, name: Chat.TCP.ClientSupervisor, strategy: :one_for_one},
      {Chat.TCP.Server, Application.fetch_env!(:chat, :tcp_port)},

      # Browser: the chat page plus a WebSocket per tab.
      {Bandit, plug: Chat.Web.Router, port: Application.fetch_env!(:chat, :http_port), ip: :any}
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: Chat.Supervisor)
  end
end
