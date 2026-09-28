defmodule Chat.WebTest do
  use ExUnit.Case, async: true
  import Plug.Test

  alias Chat.Web.Router

  @port Application.compile_env!(:chat, :http_port)

  defp unique(prefix), do: "#{prefix}#{System.unique_integer([:positive])}"

  describe "router" do
    test "serves the chat page" do
      conn = Router.call(conn(:get, "/"), [])
      assert conn.status == 200
      assert conn.resp_body =~ "<title>Elixir Chat</title>"
    end

    test "serves static assets" do
      assert Router.call(conn(:get, "/app.js"), []).status == 200
      assert Router.call(conn(:get, "/app.css"), []).status == 200
    end

    test "has a health check for the host" do
      conn = Router.call(conn(:get, "/healthz"), [])
      assert {conn.status, conn.resp_body} == {200, "ok"}
    end

    test "404s everything else" do
      assert Router.call(conn(:get, "/nope"), []).status == 404
    end
  end

  describe "websocket" do
    test "connecting with a nick welcomes you into the lobby" do
      nick = unique("web")
      socket = ws_connect("/ws?nick=#{nick}")

      assert %{"type" => "welcome", "nick" => ^nick} = ws_recv(socket)
      assert %{"type" => "entered", "room" => "lobby", "members" => members} = ws_recv(socket)
      assert nick in members
    end

    test "browser and telnet users share rooms" do
      room = unique("room")
      web = ws_connect("/ws?nick=#{unique("web")}")
      ws_send(web, "/join #{room}")
      assert %{"history" => []} = ws_expect(web, "entered", room)

      {:ok, telnet} =
        :gen_tcp.connect(~c"localhost", Application.fetch_env!(:chat, :tcp_port), [
          :binary,
          packet: :line,
          active: false
        ])

      :ok = :gen_tcp.send(telnet, "/join #{room}\r\nhello from telnet\r\n")

      assert %{"nick" => "guest" <> _, "text" => "hello from telnet", "at" => at} =
               ws_expect(web, "message", room)

      assert {:ok, _, 0} = DateTime.from_iso8601(at)
    end

    test "errors come back as error frames" do
      web = ws_connect("/ws")
      ws_send(web, "/bogus")
      assert %{"text" => "Unknown command" <> _} = ws_expect(web, "error")
    end

    test "/quit closes the connection normally" do
      web = ws_connect("/ws")
      ws_send(web, "/quit")
      assert {:close, 1000} = ws_expect_close(web)
    end
  end

  describe "heartbeat" do
    test "pings the browser so idle proxies keep the connection open" do
      assert {:push, {:ping, ""}, :state} = Chat.Web.Socket.handle_info(:heartbeat, :state)
    end
  end

  # -- A tiny WebSocket client, just enough for these tests ------------------

  defp ws_connect(path) do
    {:ok, socket} =
      :gen_tcp.connect(~c"localhost", @port, [:binary, active: false, packet: :http_bin])

    :ok =
      :gen_tcp.send(socket, """
      GET #{path} HTTP/1.1\r
      Host: localhost\r
      Upgrade: websocket\r
      Connection: Upgrade\r
      Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r
      Sec-WebSocket-Version: 13\r
      \r
      """)

    assert {:ok, {:http_response, _, 101, _}} = :gen_tcp.recv(socket, 0, 1_000)
    skip_headers(socket)
    :ok = :inet.setopts(socket, packet: :raw)
    socket
  end

  defp skip_headers(socket) do
    case :gen_tcp.recv(socket, 0, 1_000) do
      {:ok, :http_eoh} -> :ok
      {:ok, {:http_header, _, _, _, _}} -> skip_headers(socket)
    end
  end

  # Client frames must be masked; an all-zero mask keeps the payload as-is.
  defp ws_send(socket, text) when byte_size(text) < 126 do
    :ok = :gen_tcp.send(socket, <<0x81, 1::1, byte_size(text)::7, 0::32, text::binary>>)
  end

  # Returns the next frame: a decoded JSON map, or {:close, code}.
  defp ws_recv(socket) do
    {:ok, <<_fin::1, _rsv::3, opcode::4, 0::1, len::7>>} = :gen_tcp.recv(socket, 2, 1_000)

    len =
      case len do
        126 -> with {:ok, <<n::16>>} <- :gen_tcp.recv(socket, 2, 1_000), do: n
        127 -> with {:ok, <<n::64>>} <- :gen_tcp.recv(socket, 8, 1_000), do: n
        n -> n
      end

    {:ok, payload} = if len > 0, do: :gen_tcp.recv(socket, len, 1_000), else: {:ok, ""}

    case opcode do
      0x1 -> JSON.decode!(payload)
      0x8 -> {:close, binary_part(payload, 0, 2) |> :binary.decode_unsigned()}
    end
  end

  defp ws_expect(socket, type, room \\ nil) do
    case ws_recv(socket) do
      %{"type" => ^type} = frame when room == nil or :erlang.map_get("room", frame) == room ->
        frame

      {:close, _} = close ->
        flunk("connection closed while waiting for #{type}: #{inspect(close)}")

      _other ->
        ws_expect(socket, type, room)
    end
  end

  defp ws_expect_close(socket) do
    case ws_recv(socket) do
      {:close, _} = close -> close
      _other -> ws_expect_close(socket)
    end
  end
end
