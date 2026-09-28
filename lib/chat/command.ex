defmodule Chat.Command do
  @moduledoc """
  Turns one line of user input into a command.

  Lines starting with `/` are commands; everything else is a chat message.
  Parsing is pure (no processes involved), which keeps it easy to test.
  """

  @max_message_length 500

  @type t ::
          :empty
          | :leave
          | :who
          | :rooms
          | :help
          | :quit
          | {:say, String.t()}
          | {:join, String.t()}
          | {:nick, String.t()}
          | {:error, String.t()}

  @spec parse(binary()) :: t()
  def parse(line) when is_binary(line) do
    if String.valid?(line) do
      line |> strip_control_chars() |> String.trim() |> parse_line()
    else
      {:error, "Messages must be valid UTF-8."}
    end
  end

  defp parse_line(""), do: :empty
  defp parse_line("/" <> _ = line), do: parse_command(line)
  defp parse_line(text), do: {:say, String.slice(text, 0, @max_message_length)}

  defp parse_command(line) do
    {name, arg} =
      case String.split(line, ~r/\s+/, parts: 2) do
        [name, arg] -> {String.downcase(name), arg}
        [name] -> {String.downcase(name), ""}
      end

    case name do
      "/join" -> with {:ok, room} <- validate_room(arg), do: {:join, room}
      "/nick" -> with {:ok, nick} <- validate_nick(arg), do: {:nick, nick}
      "/leave" -> :leave
      "/who" -> :who
      "/rooms" -> :rooms
      "/help" -> :help
      "/quit" -> :quit
      _ -> {:error, "Unknown command #{name}. Type /help to see what you can do."}
    end
  end

  @doc "Checks a nickname: 1-20 letters, numbers, `-` or `_`."
  @spec validate_nick(term()) :: {:ok, String.t()} | {:error, String.t()}
  def validate_nick(nick) when is_binary(nick) do
    if String.match?(nick, ~r/^[A-Za-z0-9_-]{1,20}$/) do
      {:ok, nick}
    else
      {:error, "Nicknames are 1-20 characters: letters, numbers, - or _. Usage: /nick <name>"}
    end
  end

  def validate_nick(_), do: validate_nick("")

  defp validate_room(room) do
    room = room |> String.trim_leading("#") |> String.downcase()

    if String.match?(room, ~r/^[a-z0-9_-]{1,24}$/) do
      {:ok, room}
    else
      {:error, "Room names are 1-24 characters: letters, numbers, - or _. Usage: /join <room>"}
    end
  end

  # Drops ASCII/Unicode control characters (escape codes, bells, newlines...).
  # Without this, a telnet user could send ANSI escapes to everyone's terminal.
  defp strip_control_chars(text) do
    for <<char::utf8 <- text>>, not control_char?(char), into: "", do: <<char::utf8>>
  end

  defp control_char?(char), do: char < 0x20 or char in 0x7F..0x9F
end
