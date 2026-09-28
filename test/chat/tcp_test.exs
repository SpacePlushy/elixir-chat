defmodule Chat.TCPTest do
  use ExUnit.Case, async: true

  @port Application.compile_env!(:chat, :tcp_port)

  defp unique(prefix), do: "#{prefix}#{System.unique_integer([:positive])}"

  defp connect do
    {:ok, socket} =
      :gen_tcp.connect(~c"localhost", @port, [:binary, packet: :line, active: false])

    socket
  end

  defp send_line(socket, line), do: :ok = :gen_tcp.send(socket, line <> "\r\n")

  # Reads lines until one contains `expected`, returning that line.
  defp expect(socket, expected) do
    case :gen_tcp.recv(socket, 0, 1_000) do
      {:ok, line} ->
        if String.contains?(line, expected), do: line, else: expect(socket, expected)

      {:error, reason} ->
        flunk("never received #{inspect(expected)} (#{inspect(reason)})")
    end
  end

  # Other tests' clients may be starting up or shutting down concurrently.
  defp state_of(pid) do
    :sys.get_state(pid)
  catch
    :exit, _ -> nil
  end

  # Connects, picks a nickname and moves into `room`.
  defp connect_as(nick, room) do
    socket = connect()
    expect(socket, "Welcome")
    send_line(socket, "/nick #{nick}")
    expect(socket, "You are now known as #{nick}")
    send_line(socket, "/join #{room}")
    expect(socket, "You joined ##{room}")
    socket
  end

  test "new connections are welcomed into the lobby" do
    socket = connect()
    assert expect(socket, "Welcome") =~ "/help"
    assert expect(socket, "You joined #lobby") =~ "\r\n"
  end

  test "two telnet users can talk to each other" do
    room = unique("room")
    alice = connect_as(unique("alice"), room)
    bob_nick = unique("bob")
    bob = connect_as(bob_nick, room)

    expect(alice, "#{bob_nick} joined ##{room}")
    send_line(bob, "hi alice")
    assert expect(alice, "hi alice") =~ ~r/^\[\d\d:\d\d\] <#{bob_nick}> hi alice\r\n$/
  end

  test "errors are shown with a !" do
    socket = connect()
    send_line(socket, "/bogus")
    assert expect(socket, "Unknown command") =~ ~r/^! /
  end

  test "/quit says goodbye and closes the connection" do
    socket = connect()
    send_line(socket, "/quit")
    expect(socket, "Bye")
    assert {:error, :closed} = :gen_tcp.recv(socket, 0, 1_000)
  end

  test "when someone disconnects, the room is told" do
    room = unique("room")
    alice = connect_as(unique("alice"), room)
    bob_nick = unique("bob")
    bob = connect_as(bob_nick, room)

    :gen_tcp.close(bob)
    expect(alice, "#{bob_nick} left ##{room}")
  end

  test "a crashed connection doesn't affect anyone else" do
    room = unique("room")
    alice = connect_as(unique("alice"), room)
    bob_nick = unique("bob")
    _bob = connect_as(bob_nick, room)

    # Find bob's connection process by nickname and kill it.
    [bob_pid] =
      for {_, pid, _, _} <- DynamicSupervisor.which_children(Chat.TCP.ClientSupervisor),
          match?(%{session: %{nick: ^bob_nick}}, state_of(pid)),
          do: pid

    Process.exit(bob_pid, :kill)
    expect(alice, "#{bob_nick} left ##{room}")

    send_line(alice, "still works")
    expect(alice, "still works")
    assert expect(connect(), "Welcome")
  end
end
