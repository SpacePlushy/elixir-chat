// Browser client for Elixir Chat.
//
// It sends exactly what you type (the same lines a telnet user would send)
// and renders the JSON events the server pushes back. All user-provided text
// goes through textContent, never innerHTML.
(() => {
  "use strict";

  const $ = (id) => document.getElementById(id);
  const gate = $("gate");
  const gateForm = $("gate-form");
  const nickInput = $("nick-input");
  const app = $("app");
  const log = $("log");
  const roomName = $("room-name");
  const statusEl = $("status");
  const meNick = $("me-nick");
  const membersEl = $("members");
  const roomsEl = $("rooms");
  const sidebar = $("sidebar");
  const peopleToggle = $("people-toggle");
  const composer = $("composer");
  const input = $("input");

  const NICK_KEY = "elixir-chat:nick";
  const LOBBY = "lobby";
  const NICK_COLORS = 8;

  const state = {
    socket: null,
    nick: null,
    room: null,
    members: [],
    retries: 0,
    rejoin: null, // room to go back to after a reconnect
    showRooms: false, // true when the user typed /rooms themselves
    lastSent: "",
    unread: 0,
  };

  // Storage can be unavailable (private mode, blocked site data); that's fine.
  const storage = {
    get(key) { try { return localStorage.getItem(key); } catch { return null; } },
    set(key, value) { try { localStorage.setItem(key, value); } catch { /* ignore */ } },
  };

  // -- Nickname gate --------------------------------------------------------

  nickInput.value = storage.get(NICK_KEY) || "";
  nickInput.focus();

  gateForm.addEventListener("submit", (event) => {
    event.preventDefault();
    state.nick = nickInput.value.trim();
    storage.set(NICK_KEY, state.nick);
    gate.hidden = true;
    app.hidden = false;
    connect();
    input.focus();
  });

  // -- Connection -----------------------------------------------------------

  function connect() {
    const scheme = location.protocol === "https:" ? "wss:" : "ws:";
    const socket = new WebSocket(`${scheme}//${location.host}/ws?nick=${encodeURIComponent(state.nick || "")}`);
    state.socket = socket;
    setStatus(state.retries ? "reconnecting" : "connecting");

    socket.addEventListener("open", () => {
      state.retries = 0;
      setStatus("connected");
    });

    socket.addEventListener("message", (event) => handle(JSON.parse(event.data)));

    socket.addEventListener("close", (event) => {
      if (state.socket !== socket) return;

      if (event.code === 1000 && event.reason === "bye") {
        setStatus("closed");
        input.disabled = true;
        note("You left the chat. Reload the page to join again.");
        return;
      }

      state.rejoin = state.room;
      setStatus("reconnecting");
      const delay = Math.min(10000, 500 * 2 ** state.retries++);
      setTimeout(connect, delay);
    });
  }

  function send(text) {
    if (state.socket && state.socket.readyState === WebSocket.OPEN) {
      state.socket.send(text);
      return true;
    }
    return false;
  }

  function setStatus(status) {
    statusEl.dataset.state = status;
    statusEl.textContent = {
      connecting: "Connecting",
      connected: "Connected",
      reconnecting: "Reconnecting",
      closed: "Disconnected",
    }[status];
  }

  // -- Server events --------------------------------------------------------

  function handle(event) {
    switch (event.type) {
      case "welcome":
        setNick(event.nick);
        break;

      case "entered":
        // After a reconnect the server puts us in the lobby; go back where we were.
        if (state.rejoin && state.rejoin !== LOBBY && event.room === LOBBY) {
          send(`/join ${state.rejoin}`);
          state.rejoin = null;
          break;
        }
        state.rejoin = null;
        enterRoom(event);
        break;

      case "message":
        addMessage(event);
        break;

      case "joined":
        setMembers([...state.members, event.nick]);
        note(`→ ${event.nick} joined`);
        break;

      case "left":
        setMembers(state.members.filter((n) => n !== event.nick));
        note(`← ${event.nick} left`);
        break;

      case "renamed":
        setMembers(state.members.map((n) => (n === event.from ? event.to : n)));
        note(`${event.from} is now ${event.to}`);
        break;

      case "nick": {
        const old = state.nick;
        setNick(event.nick);
        storage.set(NICK_KEY, event.nick);
        setMembers(state.members.map((n) => (n === old ? event.nick : n)));
        note(`You're now ${event.nick}`);
        break;
      }

      case "parted":
        leaveRoom(event.room);
        break;

      case "who":
        setMembers(event.members);
        note(`In #${event.room}: ${event.members.join(", ")}`);
        break;

      case "rooms":
        renderRooms(event.rooms);
        if (state.showRooms) {
          state.showRooms = false;
          note(event.rooms.length
            ? `Active rooms: ${event.rooms.map((r) => `#${r.name} (${r.count})`).join(", ")}`
            : "No active rooms. Start one with /join name");
        }
        break;

      case "info":
        note(event.text, "info");
        break;

      case "error":
        note(event.text, "error");
        break;
    }
  }

  function enterRoom({ room, members, history }) {
    state.room = room;
    roomName.textContent = `#${room}`;
    input.placeholder = `Message #${room}`;
    document.title = `#${room} · Elixir Chat`;
    log.replaceChildren();
    history.forEach((message) => addMessage(message, { history: true }));
    note(history.length ? `You joined #${room}. Earlier messages are above.` : `You joined #${room}. It's quiet so far.`);
    setMembers(members);
    refreshRooms();
  }

  function leaveRoom(room) {
    state.room = null;
    roomName.textContent = "No room";
    input.placeholder = "Type /join name to pick a room";
    document.title = "Elixir Chat";
    setMembers([]);
    note(`You left #${room}. Pick a room from the list or type /join name.`);
    refreshRooms();
  }

  function setNick(nick) {
    state.nick = nick;
    meNick.textContent = nick;
  }

  function setMembers(members) {
    state.members = [...new Set(members)].sort((a, b) => a.localeCompare(b));
    membersEl.replaceChildren(...state.members.map((nick) => {
      const item = el("li", null, nick);
      item.style.setProperty("--nick", nickColor(nick));
      if (nick === state.nick) item.classList.add("me-item");
      return item;
    }));
    peopleToggle.textContent = `${state.members.length} here`;
  }

  function renderRooms(rooms) {
    roomsEl.replaceChildren(...rooms.map(({ name, count }) => {
      const button = el("button");
      button.type = "button";
      button.append(el("span", null, `#${name}`), el("span", "count", String(count)));
      if (name === state.room) button.setAttribute("aria-current", "true");
      button.addEventListener("click", () => {
        if (name !== state.room) send(`/join ${name}`);
        closeSidebar();
      });
      return el("li", null, button);
    }));
  }

  function refreshRooms() {
    send("/rooms");
  }

  // -- Rendering ------------------------------------------------------------

  function addMessage({ nick, text, at }, { history = false } = {}) {
    const row = el("div", "msg");
    const time = el("time", "msg-time", formatTime(at));
    time.dateTime = at;
    const who = el("span", "msg-nick", nick);
    who.style.setProperty("--nick", nickColor(nick));
    row.append(time, who, el("p", "msg-text", text));

    if (nick === state.nick) row.classList.add("mine");
    else if (mentionsMe(text)) row.classList.add("mention");

    append(row);

    if (!history && document.hidden) {
      state.unread += 1;
      document.title = `(${state.unread}) #${state.room} · Elixir Chat`;
    }
  }

  function note(text, kind) {
    append(el("p", kind ? `note ${kind}` : "note", text));
  }

  // Keep the view pinned to the newest message, unless the reader scrolled up.
  function append(node) {
    const atBottom = log.scrollHeight - log.scrollTop - log.clientHeight < 48;
    log.append(node);
    if (atBottom) log.scrollTop = log.scrollHeight;
  }

  function el(tag, className, content) {
    const node = document.createElement(tag);
    if (className) node.className = className;
    if (typeof content === "string") node.textContent = content;
    else if (content) node.append(content);
    return node;
  }

  function nickColor(nick) {
    let hash = 0;
    for (const char of nick.toLowerCase()) hash = (hash * 31 + char.codePointAt(0)) >>> 0;
    return `var(--nick-${hash % NICK_COLORS})`;
  }

  function mentionsMe(text) {
    // Nicknames are only [A-Za-z0-9_-], so they're safe to put in a pattern.
    if (!state.nick) return false;
    return new RegExp(`(^|[^\\w-])${state.nick}($|[^\\w-])`, "i").test(text);
  }

  function formatTime(iso) {
    return new Date(iso).toLocaleTimeString([], { hour: "numeric", minute: "2-digit" });
  }

  // -- Input ----------------------------------------------------------------

  composer.addEventListener("submit", (event) => {
    event.preventDefault();
    const text = input.value.trim();
    if (!text) return;

    if (/^\/rooms\b/i.test(text)) state.showRooms = true;

    if (send(text)) {
      state.lastSent = text;
      input.value = "";
    } else {
      note("Not connected right now, so that wasn't sent. It's still in the box; press Send again once connected.", "error");
    }
  });

  // Arrow-up in an empty box brings back the last thing you sent.
  input.addEventListener("keydown", (event) => {
    if (event.key === "ArrowUp" && !input.value && state.lastSent) {
      event.preventDefault();
      input.value = state.lastSent;
    }
  });

  peopleToggle.addEventListener("click", () => {
    const open = sidebar.dataset.open !== "true";
    sidebar.dataset.open = String(open);
    peopleToggle.setAttribute("aria-expanded", String(open));
  });

  function closeSidebar() {
    sidebar.dataset.open = "false";
    peopleToggle.setAttribute("aria-expanded", "false");
  }

  document.addEventListener("visibilitychange", () => {
    if (!document.hidden && state.unread) {
      state.unread = 0;
      document.title = state.room ? `#${state.room} · Elixir Chat` : "Elixir Chat";
    }
  });

  // Keep the room list fresh while the tab is open.
  setInterval(() => { if (!document.hidden) refreshRooms(); }, 15000);
})();
