defmodule Chat.RoomsTest do
  use ExUnit.Case, async: true

  alias Chat.Rooms

  setup do
    %{room: "room-#{System.unique_integer([:positive])}"}
  end

  test "joining starts the room on demand and returns a snapshot", %{room: room} do
    assert Rooms.list() |> List.keyfind(room, 0) == nil
    assert {:ok, %{members: ["alice"], history: []}} = Rooms.join(room, "alice")
    assert List.keyfind(Rooms.list(), room, 0) == {room, 1}
  end

  test "nicknames are unique within a room, ignoring case", %{room: room} do
    {:ok, _} = Rooms.join(room, "alice")
    {_bob, result} = start_member(fn -> Rooms.join(room, "ALICE") end)
    assert result == {:error, :nick_taken}
  end

  test "existing members hear about new members", %{room: room} do
    {:ok, _} = Rooms.join(room, "alice")
    {_bob, {:ok, %{members: members}}} = start_member(fn -> Rooms.join(room, "bob") end)

    assert members == ["alice", "bob"]
    assert_receive {:chat, {:joined, ^room, "bob"}}
  end

  test "messages go to every member, including the sender", %{room: room} do
    {:ok, _} = Rooms.join(room, "alice")
    {_bob, :ok} = start_member(fn -> Rooms.join(room, "bob") && Rooms.say(room, "hi alice") end)

    assert_receive {:chat, {:message, ^room, "bob", "hi alice", %DateTime{}}}

    :ok = Rooms.say(room, "hi bob")
    assert_receive {:chat, {:message, ^room, "alice", "hi bob", %DateTime{}}}
  end

  test "only members can speak", %{room: room} do
    {:ok, _} = Rooms.join(room, "alice")
    {_stranger, result} = start_member(fn -> Rooms.say(room, "let me in") end)
    assert result == {:error, :not_member}
  end

  test "new members get recent history, oldest first", %{room: room} do
    {:ok, _} = Rooms.join(room, "alice")
    for n <- 1..60, do: :ok = Rooms.say(room, "message #{n}")

    {_bob, {:ok, %{history: history}}} = start_member(fn -> Rooms.join(room, "bob") end)

    assert length(history) == 50
    assert %{nick: "alice", text: "message 11", at: %DateTime{}} = hd(history)
    assert List.last(history).text == "message 60"
  end

  test "leaving tells the others", %{room: room} do
    {:ok, _} = Rooms.join(room, "alice")
    {bob, :ok} = start_member(fn -> Rooms.join(room, "bob") && Rooms.leave(room) end)

    assert_receive {:chat, {:left, ^room, "bob"}}
    assert Rooms.members(room) == ["alice"]
    assert Process.alive?(bob)
  end

  test "a member whose process dies is removed automatically", %{room: room} do
    {:ok, _} = Rooms.join(room, "alice")
    {bob, {:ok, _}} = start_member(fn -> Rooms.join(room, "bob") end)

    Process.unlink(bob)
    Process.exit(bob, :kill)

    assert_receive {:chat, {:left, ^room, "bob"}}
    assert Rooms.members(room) == ["alice"]
  end

  test "renaming tells the others and respects uniqueness", %{room: room} do
    {:ok, _} = Rooms.join(room, "alice")

    {_bob, result} =
      start_member(fn -> Rooms.join(room, "bob") && Rooms.rename(room, "alice") end)

    assert result == {:error, :nick_taken}

    :ok = Rooms.rename(room, "alicia")
    assert Rooms.members(room) == ["alicia", "bob"]
    refute_receive {:chat, {:renamed, _, _, _}}
  end

  test "an empty room shuts itself down after the idle timeout", %{room: room} do
    {:ok, _} = Rooms.join(room, "alice")
    [{pid, _}] = Registry.lookup(Chat.RoomRegistry, room)
    ref = Process.monitor(pid)

    :ok = Rooms.leave(room)

    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 1_000
    assert List.keyfind(Rooms.list(), room, 0) == nil
  end

  test "a room with members stays up past the idle timeout", %{room: room} do
    {:ok, _} = Rooms.join(room, "alice")
    [{pid, _}] = Registry.lookup(Chat.RoomRegistry, room)
    ref = Process.monitor(pid)

    refute_receive {:DOWN, ^ref, _, _, _}, 300
  end

  test "a crashed room is replaced transparently on the next call", %{room: room} do
    {:ok, _} = Rooms.join(room, "alice")
    [{pid, _}] = Registry.lookup(Chat.RoomRegistry, room)
    ref = Process.monitor(pid)
    Process.exit(pid, :kill)
    assert_receive {:DOWN, ^ref, _, _, _}

    # The new room has no memory of alice, but it answers.
    assert Rooms.members(room) == []
    assert Rooms.say(room, "hello?") == {:error, :not_member}
  end

  # Runs `fun` in a second process that stays alive afterwards, so it can
  # act as another chat member. Returns {pid, fun_result}.
  defp start_member(fun) do
    test = self()

    pid =
      spawn_link(fn ->
        send(test, {:member_result, self(), fun.()})
        Process.sleep(:infinity)
      end)

    assert_receive {:member_result, ^pid, result}
    {pid, result}
  end
end
