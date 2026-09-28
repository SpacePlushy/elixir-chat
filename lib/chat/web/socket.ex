defmodule Chat.Web.Socket do
  @moduledoc """
  One browser connection. Like `Chat.TCP.Client`, it owns a `Chat.Session`,
  but it speaks JSON over a WebSocket instead of text lines over TCP.

  The browser sends plain text frames (exactly what a telnet user would
  type) and receives one JSON object per output, tagged by `"type"`.
  """

  @behaviour WebSock

  alias Chat.Session

  # Hosting proxies drop idle connections, so ping the browser regularly.
  # Browsers answer pings automatically.
  @heartbeat_ms 25_000

  @impl true
  def init(%{nick: nick}) do
    {session, outputs} = Session.start(nick)
    schedule_heartbeat()
    push(outputs, session)
  end

  @impl true
  def handle_in({text, opcode: :text}, session) do
    {session, outputs} = Session.handle_input(session, text)
    push(outputs, session)
  end

  def handle_in({_binary, opcode: :binary}, session), do: {:ok, session}

  @impl true
  def handle_info({:chat, _event} = message, session) do
    push(Session.handle_event(session, message), session)
  end

  def handle_info(:heartbeat, state) do
    schedule_heartbeat()
    {:push, {:ping, ""}, state}
  end

  def handle_info(_other, session), do: {:ok, session}

  defp schedule_heartbeat, do: Process.send_after(self(), :heartbeat, @heartbeat_ms)

  defp push(outputs, session) do
    frames = for output <- outputs, output != :quit, do: {:text, JSON.encode!(encode(output))}

    cond do
      :quit in outputs -> {:stop, :normal, {1000, "bye"}, frames, session}
      frames == [] -> {:ok, session}
      true -> {:push, frames, session}
    end
  end

  defp encode({:welcome, nick}), do: %{type: "welcome", nick: nick}

  defp encode({:entered, room, members, history}) do
    history = for m <- history, do: %{nick: m.nick, text: m.text, at: DateTime.to_iso8601(m.at)}
    %{type: "entered", room: room, members: members, history: history}
  end

  defp encode({:message, room, nick, text, at}),
    do: %{type: "message", room: room, nick: nick, text: text, at: DateTime.to_iso8601(at)}

  defp encode({:joined, room, nick}), do: %{type: "joined", room: room, nick: nick}
  defp encode({:left, room, nick}), do: %{type: "left", room: room, nick: nick}
  defp encode({:renamed, room, from, to}), do: %{type: "renamed", room: room, from: from, to: to}
  defp encode({:parted, room}), do: %{type: "parted", room: room}
  defp encode({:nick, nick}), do: %{type: "nick", nick: nick}
  defp encode({:who, room, members}), do: %{type: "who", room: room, members: members}

  defp encode({:rooms, rooms}),
    do: %{type: "rooms", rooms: for({name, count} <- rooms, do: %{name: name, count: count})}

  defp encode({:info, text}), do: %{type: "info", text: text}
  defp encode({:error, text}), do: %{type: "error", text: text}
end
