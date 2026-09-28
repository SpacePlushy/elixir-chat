defmodule Chat.Session do
  @moduledoc """
  What one connected user is doing: their nick, their room, and how to react
  to what they type.

  This is plain data plus functions. It doesn't know about sockets. Each
  transport (`Chat.TCP.Client`, `Chat.Web.Socket`) owns a session, feeds it
  input and room events, and formats the outputs it gets back. That's why the
  same commands work identically over telnet and in the browser.

  Outputs are tuples like `{:entered, room, members, history}` or
  `{:error, text}`. Room events (`{:message, ...}`, `{:joined, ...}`, ...)
  come from `Chat.Room` and pass through `handle_event/2`.
  """

  alias Chat.{Command, Rooms}

  @lobby "lobby"
  @burst 5
  @burst_window_ms 5_000

  @help """
  Commands:
    /join <room>   switch to a room (it's created if it doesn't exist)
    /nick <name>   change your nickname
    /who           list people in this room
    /rooms         list active rooms
    /leave         leave the current room
    /quit          disconnect
  Anything else you type is sent to the room.\
  """

  defstruct [:nick, :room, sent_at: []]

  @type t :: %__MODULE__{nick: String.t(), room: String.t() | nil, sent_at: [integer()]}

  @doc "Starts a session, joining the lobby with `nick` or a guest nickname."
  @spec start(String.t() | nil) :: {t(), list()}
  def start(nick \\ nil) do
    {nick, notices} =
      case {nick, Command.validate_nick(nick)} do
        {nil, _} -> {guest_nick(), []}
        {_, {:ok, nick}} -> {nick, []}
        {_, {:error, reason}} -> {guest_nick(), [{:error, reason}]}
      end

    {session, replies} =
      case join(%__MODULE__{nick: nick}, @lobby) do
        {%{room: nil} = session, [{:error, reason}]} ->
          {session, replies} = join(%{session | nick: guest_nick()}, @lobby)
          {session, [{:error, reason} | replies]}

        result ->
          result
      end

    {session, [{:welcome, session.nick} | notices ++ replies]}
  end

  @doc "Handles one line the user typed."
  @spec handle_input(t(), binary()) :: {t(), list()}
  def handle_input(session, line), do: run(Command.parse(line), session)

  @doc "Filters a room event down to what this session should show."
  @spec handle_event(t(), {:chat, tuple()}) :: list()
  def handle_event(%{room: room}, {:chat, event}) when elem(event, 1) == room, do: [event]
  def handle_event(_session, {:chat, _event}), do: []

  defp run(:empty, session), do: {session, []}
  defp run({:error, reason}, session), do: {session, [{:error, reason}]}
  defp run(:help, session), do: {session, [{:info, @help}]}
  defp run(:quit, session), do: {session, [:quit]}
  defp run(:rooms, session), do: {session, [{:rooms, Rooms.list()}]}

  defp run({:nick, nick}, %{room: nil} = session), do: {%{session | nick: nick}, [{:nick, nick}]}

  defp run({:nick, nick}, session) do
    case Rooms.rename(session.room, nick) do
      :ok ->
        {%{session | nick: nick}, [{:nick, nick}]}

      {:error, :nick_taken} ->
        {session, [{:error, "#{nick} is already taken in ##{session.room}."}]}

      {:error, :not_member} ->
        rejoin(%{session | nick: nick})
    end
  end

  defp run({:join, room}, %{room: room} = session) do
    {session, [{:info, "You're already in ##{room}."}]}
  end

  defp run({:join, room}, session), do: join(session, room)

  defp run(_command, %{room: nil} = session) do
    {session, [{:error, "You're not in a room. Try /join lobby"}]}
  end

  defp run(:who, session), do: {session, [{:who, session.room, Rooms.members(session.room)}]}

  defp run(:leave, session) do
    :ok = Rooms.leave(session.room)
    {%{session | room: nil}, [{:parted, session.room}]}
  end

  defp run({:say, text}, session) do
    case throttle(session) do
      {:ok, session} -> say(session, text)
      :error -> {session, [{:error, "You're sending messages too fast, slow down a little."}]}
    end
  end

  defp say(session, text) do
    case Rooms.say(session.room, text) do
      :ok ->
        {session, []}

      # The room crashed and was replaced, so it has forgotten us. Rejoin, then resend.
      {:error, :not_member} ->
        with {%{room: room} = session, replies} when room != nil <- rejoin(session),
             {session, more} <- say(session, text) do
          {session, replies ++ more}
        end
    end
  end

  # Joins the new room first, and only then leaves the old one, so a failed
  # join leaves you where you were.
  defp join(session, room) do
    case Rooms.join(room, session.nick) do
      {:ok, %{members: members, history: history}} ->
        if session.room, do: Rooms.leave(session.room)
        {%{session | room: room}, [{:entered, room, members, history}]}

      {:error, :nick_taken} ->
        {session,
         [{:error, "The nickname #{session.nick} is taken in ##{room}. Change it with /nick"}]}
    end
  end

  defp rejoin(session) do
    case join(%{session | room: nil}, session.room) do
      {%{room: nil} = session, replies} -> {session, replies}
      result -> result
    end
  end

  defp throttle(session) do
    now = System.monotonic_time(:millisecond)
    recent = Enum.filter(session.sent_at, &(now - &1 < @burst_window_ms))

    if length(recent) < @burst do
      {:ok, %{session | sent_at: [now | recent]}}
    else
      :error
    end
  end

  defp guest_nick, do: "guest#{Enum.random(1000..9999)}"
end
