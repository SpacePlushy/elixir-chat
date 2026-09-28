defmodule Chat.TCP.Server do
  @moduledoc """
  Listens for TCP connections (telnet, `nc`) and gives each one its own
  `Chat.TCP.Client` process under `Chat.TCP.ClientSupervisor`.

  The acceptor only accepts; it never talks to clients, so a misbehaving
  client can't block new connections.
  """

  use Task, restart: :permanent

  require Logger

  def start_link(port), do: Task.start_link(__MODULE__, :listen, [port])

  def listen(port) do
    {:ok, listen_socket} =
      :gen_tcp.listen(port, [:binary, packet: :line, active: false, reuseaddr: true])

    Logger.info("Accepting telnet connections on port #{port}")
    accept_loop(listen_socket)
  end

  defp accept_loop(listen_socket) do
    {:ok, socket} = :gen_tcp.accept(listen_socket)

    # The new process must own the socket before it starts reading from it,
    # so hand it over first, then tell the client to begin.
    with {:ok, pid} <-
           DynamicSupervisor.start_child(Chat.TCP.ClientSupervisor, {Chat.TCP.Client, socket}),
         :ok <- :gen_tcp.controlling_process(socket, pid) do
      send(pid, :socket_ready)
    else
      _ -> :gen_tcp.close(socket)
    end

    accept_loop(listen_socket)
  end
end
