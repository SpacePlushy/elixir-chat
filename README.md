# Elixir Chat

A multi-room chat server written in Elixir with no web framework. You can join from a browser or from a plain terminal with `telnet`/`nc`, and everyone ends up in the same rooms.

It's a learning project. It's small enough to read in one sitting, and it uses the parts of OTP that make Elixir different: processes, supervisors, GenServers, the Registry and monitors.

[![Deploy to Render](https://render.com/images/deploy-to-render-button.svg)](https://render.com/deploy?repo=https://github.com/SpacePlushy/elixir-chat)

## Run it locally

You need Elixir 1.20 and Erlang/OTP 29 (`brew install elixir` on macOS; exact versions are in `.tool-versions`).

```sh
mix deps.get
mix run --no-halt
```

Then open <http://localhost:4000>, or connect from a terminal:

```sh
nc localhost 4040        # or: telnet localhost 4040
```

Open a few of each and talk between them.

## Commands

| Command | What it does |
| --- | --- |
| `/join <room>` | Switch rooms (a room is created the first time someone joins it) |
| `/nick <name>` | Change your nickname (unique per room) |
| `/who` | List people in your room |
| `/rooms` | List active rooms and how many people are in each |
| `/leave` | Leave your room |
| `/quit` | Disconnect |

Anything else you type is sent to your room.

## How it works

```
Chat.Supervisor (one_for_one)
├── Chat.RoomRegistry          Registry: room name → room process
├── Chat.RoomSupervisor        DynamicSupervisor
│   ├── Chat.Room "lobby"      GenServer per room, started on demand
│   └── Chat.Room "elixir"
├── Chat.TCP.ClientSupervisor  DynamicSupervisor
│   └── Chat.TCP.Client …      GenServer per telnet connection
├── Chat.TCP.Server            Task: accepts telnet connections
└── Bandit                     HTTP server: page, /healthz, and /ws
    └── Chat.Web.Socket …      process per browser tab
```

Each piece, and the idea it demonstrates:

- **`Chat.Room`** ([lib/chat/room.ex](lib/chat/room.ex)): one GenServer per room holds its members and the last 50 messages. It **monitors** every member, so when a connection dies for any reason the room gets a `:DOWN` message and tells everyone that person left. An empty room shuts itself down after 5 minutes.
- **`Chat.Rooms`** ([lib/chat/rooms.ex](lib/chat/rooms.ex)): the client API. It finds rooms through the **Registry** and starts them on demand under a **DynamicSupervisor**. If a room stops or crashes between the lookup and the call, it retries, and the next call gets a fresh room.
- **`Chat.Session`** ([lib/chat/session.ex](lib/chat/session.ex)): one user's state as plain data (nick, room, rate limit). It knows nothing about sockets, which is why telnet and the browser behave identically. If a room crashes, the session quietly rejoins on your next message ("let it crash", then heal).
- **`Chat.Command`** ([lib/chat/command.ex](lib/chat/command.ex)): a pure parser for input lines. It also strips control characters so nobody can send terminal escape codes to other telnet users.
- **`Chat.TCP.Server` / `Chat.TCP.Client`** ([lib/chat/tcp/](lib/chat/tcp/)): the acceptor hands each socket to its own supervised process. A client uses `active: :once`, so typed lines and room events arrive in the same mailbox and are handled one at a time.
- **`Chat.Web.Router` / `Chat.Web.Socket`** ([lib/chat/web/](lib/chat/web/)): Plug and Bandit serve the page in `priv/static/` and upgrade `/ws` to a WebSocket. The browser sends exactly what a telnet user would type and gets JSON events back.

## Tests

```sh
mix test
```

The tests exercise real processes and real sockets: rooms crashing and recovering, members being killed, and telnet and WebSocket clients (with a tiny hand-rolled WebSocket client in `test/chat/web_test.exs`).

## Deployment

The app runs on [Render](https://render.com)'s free tier as a Docker web service, defined in `render.yaml`:

- The `Dockerfile` builds an OTP release and copies it into a slim Debian image.
- GitHub Actions (`.github/workflows/ci.yml`) checks formatting, compiles with warnings as errors, runs the tests and builds the Docker image.
- Render's `autoDeployTrigger: checksPass` deploys a commit to `main` only after those checks pass.

A couple of things to know about the free tier:

- **The browser client only.** Render exposes one HTTP port per service, so the telnet port isn't reachable there. Use telnet locally.
- **It sleeps when idle.** After about 15 minutes without traffic the service spins down, so the next visit takes a little while to wake it. Rooms live in memory, so they reset when that happens.
