defmodule Chat.Web.Router do
  @moduledoc """
  HTTP routes: the chat page, its static assets, a health check for the
  host, and `/ws`, which upgrades to a WebSocket handled by `Chat.Web.Socket`.
  """

  use Plug.Router

  plug(Plug.Static, at: "/", from: {:chat, "priv/static"}, only: ~w(app.js app.css favicon.svg))
  plug(:match)
  plug(:dispatch)

  get "/" do
    conn
    |> put_resp_content_type("text/html")
    |> send_file(200, Application.app_dir(:chat, "priv/static/index.html"))
  end

  get "/healthz" do
    send_resp(conn, 200, "ok")
  end

  get "/ws" do
    conn = fetch_query_params(conn)

    conn
    |> WebSockAdapter.upgrade(Chat.Web.Socket, %{nick: conn.query_params["nick"]},
      timeout: 60_000
    )
    |> halt()
  end

  match _ do
    send_resp(conn, 404, "not found")
  end
end
