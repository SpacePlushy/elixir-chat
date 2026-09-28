defmodule Chat.TCP.Client do
  @moduledoc """
  One telnet connection: a GenServer that owns the socket and a `Chat.Session`.

  The socket runs in `active: :once` mode, so lines typed by the user arrive
  as `{:tcp, socket, line}` messages in the same mailbox as room events
  (`{:chat, event}`). One process, one mailbox, handled in order.
  """

  use GenServer, restart: :temporary

  alias Chat.Session

  def start_link(socket), do: GenServer.start_link(__MODULE__, socket)

  @impl true
  def init(socket), do: {:ok, %{socket: socket, session: nil}}

  @impl true
  def handle_info(:socket_ready, state) do
    {session, outputs} = Session.start()
    reply(%{state | session: session}, outputs)
  end

  def handle_info({:tcp, _socket, line}, state) do
    {session, outputs} = Session.handle_input(state.session, line)
    reply(%{state | session: session}, outputs)
  end

  def handle_info({:chat, _event} = message, state) do
    reply(state, Session.handle_event(state.session, message))
  end

  def handle_info({:tcp_closed, _socket}, state), do: {:stop, :normal, state}
  def handle_info({:tcp_error, _socket, _reason}, state), do: {:stop, :normal, state}

  defp reply(state, outputs) do
    :gen_tcp.send(state.socket, Enum.map(outputs, &format/1))

    if :quit in outputs do
      :gen_tcp.close(state.socket)
      {:stop, :normal, state}
    else
      :inet.setopts(state.socket, active: :once)
      {:noreply, state}
    end
  end

  defp format({:welcome, nick}),
    do: line("Welcome to Elixir Chat, #{nick}! Type /help for commands.")

  defp format({:entered, room, members, history}) do
    [
      line("* You joined ##{room}. Here now: #{Enum.join(members, ", ")}"),
      Enum.map(history, &format({:message, room, &1.nick, &1.text, &1.at}))
    ]
  end

  defp format({:message, _room, nick, text, at}),
    do: line("[#{Calendar.strftime(at, "%H:%M")}] <#{nick}> #{text}")

  defp format({:joined, room, nick}), do: line("* #{nick} joined ##{room}")
  defp format({:left, room, nick}), do: line("* #{nick} left ##{room}")
  defp format({:renamed, _room, from, to}), do: line("* #{from} is now known as #{to}")
  defp format({:parted, room}), do: line("* You left ##{room}.")
  defp format({:nick, nick}), do: line("* You are now known as #{nick}.")
  defp format({:who, room, members}), do: line("* In ##{room}: #{Enum.join(members, ", ")}")
  defp format({:rooms, []}), do: line("* No active rooms. Start one with /join <room>")

  defp format({:rooms, rooms}),
    do: line("* Active rooms: " <> Enum.map_join(rooms, ", ", fn {r, n} -> "##{r} (#{n})" end))

  defp format({:info, text}), do: line("* " <> text)
  defp format({:error, text}), do: line("! " <> text)
  defp format(:quit), do: line("* Bye!")

  # Telnet expects CRLF line endings.
  defp line(text), do: String.replace(text, "\n", "\r\n") <> "\r\n"
end
