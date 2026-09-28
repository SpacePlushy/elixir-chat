defmodule Chat.Rooms do
  @moduledoc """
  Client API for chat rooms.

  Rooms are looked up by name in `Chat.RoomRegistry` and started on demand
  under `Chat.RoomSupervisor`. All functions act on behalf of the calling
  process: `join/2` makes `self()` a member, and that process then receives
  `{:chat, event}` messages.
  """

  alias Chat.Room

  @registry Chat.RoomRegistry

  @type snapshot :: %{members: [String.t()], history: [map()]}

  @spec join(String.t(), String.t()) :: {:ok, snapshot()} | {:error, :nick_taken}
  def join(room, nick), do: call(room, {:join, self(), nick})

  @spec leave(String.t()) :: :ok
  def leave(room) do
    case lookup(room) do
      nil -> :ok
      _pid -> call(room, {:leave, self()})
    end
  end

  @spec say(String.t(), String.t()) :: :ok | {:error, :not_member}
  def say(room, text), do: call(room, {:say, self(), text})

  @spec rename(String.t(), String.t()) :: :ok | {:error, :nick_taken | :not_member}
  def rename(room, nick), do: call(room, {:rename, self(), nick})

  @spec members(String.t()) :: [String.t()]
  def members(room), do: call(room, :members)

  @doc "Lists running rooms as `{name, member_count}`, sorted by name."
  @spec list() :: [{String.t(), non_neg_integer()}]
  def list do
    entries = Registry.select(@registry, [{{:"$1", :"$2", :"$3"}, [], [{{:"$1", :"$2", :"$3"}}]}])

    for {name, pid, count} <- Enum.sort(entries), Process.alive?(pid), do: {name, count}
  end

  # A room can stop (idle timeout) or crash between our lookup and our call.
  # When that happens, look it up again, which starts a fresh one if needed.
  defp call(room, message, attempts \\ 3) do
    GenServer.call(ensure_started(room), message)
  catch
    :exit, {reason, _} when reason in [:noproc, :normal] and attempts > 1 ->
      call(room, message, attempts - 1)
  end

  defp ensure_started(room) do
    with nil <- lookup(room) do
      case DynamicSupervisor.start_child(Chat.RoomSupervisor, {Room, room}) do
        {:ok, pid} -> pid
        {:error, {:already_started, pid}} -> pid
      end
    end
  end

  # The Registry removes a dead process's entry asynchronously, so for a brief
  # moment it can still return a room that has just stopped. Treat that as gone.
  defp lookup(room) do
    case Registry.lookup(@registry, room) do
      [{pid, _count}] -> if Process.alive?(pid), do: pid
      [] -> nil
    end
  end
end
