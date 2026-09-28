defmodule Chat.Room do
  @moduledoc """
  One chat room: a GenServer that owns the member list and recent history.

  Members are plain processes (a TCP connection or a WebSocket). The room
  *monitors* each one, so when a connection dies for any reason the room gets
  a `:DOWN` message and removes it. No explicit cleanup is needed.

  Events are sent to members as `{:chat, event}` messages. Talk to rooms
  through `Chat.Rooms` rather than calling this module directly.
  """

  use GenServer, restart: :temporary

  @history_limit 50

  def start_link(name) do
    GenServer.start_link(__MODULE__, name, name: {:via, Registry, {Chat.RoomRegistry, name, 0}})
  end

  @impl true
  def init(name) do
    state = %{name: name, members: %{}, history: [], idle_timer: nil}
    {:ok, schedule_idle_check(state)}
  end

  @impl true
  def handle_call({:join, pid, nick}, _from, state) do
    cond do
      Map.has_key?(state.members, pid) ->
        {:reply, {:ok, snapshot(state)}, state}

      nick_taken?(state, nick, pid) ->
        {:reply, {:error, :nick_taken}, state}

      true ->
        member = %{nick: nick, monitor: Process.monitor(pid)}
        broadcast(state, {:joined, state.name, nick})
        state = put_in(state.members[pid], member) |> members_changed()
        {:reply, {:ok, snapshot(state)}, state}
    end
  end

  def handle_call({:leave, pid}, _from, state) do
    {:reply, :ok, remove_member(state, pid)}
  end

  def handle_call({:say, pid, text}, _from, state) do
    case state.members do
      %{^pid => %{nick: nick}} ->
        message = %{nick: nick, text: text, at: DateTime.utc_now(:second)}
        broadcast(state, {:message, state.name, nick, text, message.at})
        history = Enum.take([message | state.history], @history_limit)
        {:reply, :ok, %{state | history: history}}

      _ ->
        {:reply, {:error, :not_member}, state}
    end
  end

  def handle_call({:rename, pid, new_nick}, _from, state) do
    case state.members do
      %{^pid => %{nick: old_nick}} ->
        if nick_taken?(state, new_nick, pid) do
          {:reply, {:error, :nick_taken}, state}
        else
          state = put_in(state.members[pid].nick, new_nick)
          broadcast(state, {:renamed, state.name, old_nick, new_nick}, except: pid)
          {:reply, :ok, state}
        end

      _ ->
        {:reply, {:error, :not_member}, state}
    end
  end

  def handle_call(:members, _from, state) do
    {:reply, nicks(state), state}
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, pid, _reason}, state) do
    {:noreply, remove_member(state, pid)}
  end

  def handle_info(:idle_check, state) do
    if state.members == %{} do
      {:stop, :normal, state}
    else
      {:noreply, %{state | idle_timer: nil}}
    end
  end

  defp remove_member(state, pid) do
    case Map.pop(state.members, pid) do
      {nil, _members} ->
        state

      {member, members} ->
        Process.demonitor(member.monitor, [:flush])
        state = members_changed(%{state | members: members})
        broadcast(state, {:left, state.name, member.nick})
        state
    end
  end

  # Keeps the member count in the Registry up to date (so listing rooms needs
  # no messages) and starts or cancels the idle shutdown timer.
  defp members_changed(state) do
    Registry.update_value(Chat.RoomRegistry, state.name, fn _ -> map_size(state.members) end)

    if state.members == %{} do
      schedule_idle_check(state)
    else
      cancel_idle_check(state)
    end
  end

  defp schedule_idle_check(state) do
    state = cancel_idle_check(state)
    timeout = Application.fetch_env!(:chat, :room_idle_timeout)
    %{state | idle_timer: Process.send_after(self(), :idle_check, timeout)}
  end

  defp cancel_idle_check(%{idle_timer: nil} = state), do: state

  defp cancel_idle_check(state) do
    Process.cancel_timer(state.idle_timer)
    %{state | idle_timer: nil}
  end

  defp broadcast(state, event, opts \\ []) do
    except = Keyword.get(opts, :except)
    for pid <- Map.keys(state.members), pid != except, do: send(pid, {:chat, event})
    :ok
  end

  defp nick_taken?(state, nick, pid) do
    nick = String.downcase(nick)

    Enum.any?(state.members, fn {other, m} -> other != pid and String.downcase(m.nick) == nick end)
  end

  defp nicks(state), do: state.members |> Map.values() |> Enum.map(& &1.nick) |> Enum.sort()

  defp snapshot(state), do: %{members: nicks(state), history: Enum.reverse(state.history)}
end
