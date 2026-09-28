defmodule Chat.SessionTest do
  use ExUnit.Case, async: true

  alias Chat.{Rooms, Session}

  defp unique(prefix), do: "#{prefix}#{System.unique_integer([:positive])}"

  # Starts a session and moves it into a fresh room so tests don't share the lobby.
  defp session_in_new_room(nick \\ unique("user")) do
    {session, _} = Session.start(nick)
    room = unique("room")
    {session, [{:entered, ^room, _, _}]} = Session.handle_input(session, "/join #{room}")
    session
  end

  describe "start/1" do
    test "welcomes the user and puts them in the lobby" do
      nick = unique("frank")
      {session, replies} = Session.start(nick)

      assert session.nick == nick
      assert session.room == "lobby"
      assert [{:welcome, ^nick}, {:entered, "lobby", members, _history}] = replies
      assert nick in members
    end

    test "without a nickname, assigns a guest one" do
      {session, [{:welcome, nick} | _]} = Session.start(nil)
      assert nick =~ ~r/^guest\d+$/
      assert session.nick == nick
    end

    test "with an invalid nickname, falls back to a guest one and says why" do
      {session, replies} = Session.start("not valid!")
      assert session.nick =~ ~r/^guest\d+$/
      assert Enum.any?(replies, &match?({:error, _}, &1))
    end

    test "with a nickname taken in the lobby, falls back to a guest one and says why" do
      nick = unique("taken")
      {:ok, _} = Rooms.join("lobby", nick)

      {session, replies} = Task.await(Task.async(fn -> Session.start(nick) end))

      assert session.nick =~ ~r/^guest\d+$/
      assert session.room == "lobby"
      assert Enum.any?(replies, &match?({:error, _}, &1))
    end
  end

  describe "handle_input/2" do
    test "chat messages are sent to the current room" do
      session = session_in_new_room()
      room = session.room
      nick = session.nick

      assert {_session, []} = Session.handle_input(session, "hello world")
      assert_receive {:chat, {:message, ^room, ^nick, "hello world", _at}}
    end

    test "/join moves to the new room and leaves the old one" do
      session = session_in_new_room()
      old_room = session.room
      new_room = unique("room")

      {session, [{:entered, ^new_room, members, []}]} =
        Session.handle_input(session, "/join ##{new_room}")

      assert session.room == new_room
      assert members == [session.nick]
      refute session.nick in Rooms.members(old_room)
    end

    test "/join the room you are in just says so" do
      session = session_in_new_room()
      assert {^session, [{:info, _}]} = Session.handle_input(session, "/join #{session.room}")
    end

    test "/join a room where your nick is taken keeps you where you are" do
      session = session_in_new_room()
      busy_room = unique("room")
      parent = self()

      holder =
        spawn_link(fn ->
          {:ok, _} = Rooms.join(busy_room, session.nick)
          send(parent, :holding)
          Process.sleep(:infinity)
        end)

      assert_receive :holding
      assert {^session, [{:error, _}]} = Session.handle_input(session, "/join #{busy_room}")
      assert Process.alive?(holder)
    end

    test "/leave leaves the room, after which messages are refused" do
      session = session_in_new_room()
      room = session.room

      {session, [{:parted, ^room}]} = Session.handle_input(session, "/leave")
      assert session.room == nil
      assert {_, [{:error, _}]} = Session.handle_input(session, "anyone?")
      assert {_, [{:error, _}]} = Session.handle_input(session, "/leave")
    end

    test "/nick renames you in the room" do
      session = session_in_new_room()
      new_nick = unique("renamed")

      {session, [{:nick, ^new_nick}]} = Session.handle_input(session, "/nick #{new_nick}")
      assert session.nick == new_nick
      assert Rooms.members(session.room) == [new_nick]
    end

    test "/nick works outside a room too" do
      session = session_in_new_room()
      {session, _} = Session.handle_input(session, "/leave")
      {session, [{:nick, "solo"}]} = Session.handle_input(session, "/nick solo")
      assert session.nick == "solo"
    end

    test "/who lists the room's members" do
      session = session_in_new_room()
      room = session.room
      assert {_, [{:who, ^room, [nick]}]} = Session.handle_input(session, "/who")
      assert nick == session.nick
    end

    test "/rooms lists active rooms with member counts" do
      session = session_in_new_room()
      assert {_, [{:rooms, rooms}]} = Session.handle_input(session, "/rooms")
      assert {session.room, 1} in rooms
    end

    test "/help explains the commands" do
      {_, [{:info, help}]} = Session.handle_input(session_in_new_room(), "/help")
      assert help =~ "/join"
      assert help =~ "/nick"
    end

    test "/quit asks the transport to disconnect" do
      assert {_, [:quit]} = Session.handle_input(session_in_new_room(), "/quit")
    end

    test "parse errors are reported" do
      assert {_, [{:error, _}]} = Session.handle_input(session_in_new_room(), "/bogus")
    end

    test "flooding is rate limited" do
      session = session_in_new_room()

      session =
        Enum.reduce(1..5, session, fn n, session ->
          {session, []} = Session.handle_input(session, "message #{n}")
          session
        end)

      assert {_, [{:error, message}]} = Session.handle_input(session, "one too many")
      assert message =~ "slow down"
    end

    test "if the room crashed, the next message rejoins it and still gets delivered" do
      session = session_in_new_room()
      room = session.room
      [{pid, _}] = Registry.lookup(Chat.RoomRegistry, room)
      ref = Process.monitor(pid)
      Process.exit(pid, :kill)
      assert_receive {:DOWN, ^ref, _, _, _}

      assert {_, [{:entered, ^room, _, _}]} = Session.handle_input(session, "still here?")
      assert_receive {:chat, {:message, ^room, _, "still here?", _}}
    end
  end

  describe "handle_event/2" do
    test "passes through events for the current room" do
      session = session_in_new_room()
      event = {:joined, session.room, "someone"}
      assert Session.handle_event(session, {:chat, event}) == [event]
    end

    test "drops late events from a room you already left" do
      session = session_in_new_room()
      assert Session.handle_event(session, {:chat, {:joined, "elsewhere", "someone"}}) == []
    end
  end
end
