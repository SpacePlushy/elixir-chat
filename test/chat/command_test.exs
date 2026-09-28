defmodule Chat.CommandTest do
  use ExUnit.Case, async: true

  alias Chat.Command

  describe "parse/1 chat messages" do
    test "plain text is a message, trimmed" do
      assert Command.parse("  hello there \r\n") == {:say, "hello there"}
    end

    test "blank lines are ignored" do
      assert Command.parse("   \r\n") == :empty
    end

    test "control characters are stripped so nobody can inject terminal escapes" do
      assert Command.parse("hi \e[31mred\e[0m\a") == {:say, "hi [31mred[0m"}
    end

    test "a message made only of control characters is empty" do
      assert Command.parse("\e\a") == :empty
    end

    test "long messages are truncated to 500 characters" do
      {:say, text} = Command.parse(String.duplicate("é", 600))
      assert String.length(text) == 500
    end

    test "invalid UTF-8 is rejected" do
      assert {:error, _} = Command.parse(<<0xFF, 0xFE, ?h, ?i>>)
    end
  end

  describe "parse/1 commands" do
    test "/join takes a room name, dropping a leading # and lowercasing" do
      assert Command.parse("/join #Elixir") == {:join, "elixir"}
    end

    test "/join validates the room name" do
      assert {:error, _} = Command.parse("/join no spaces allowed")
      assert {:error, _} = Command.parse("/join " <> String.duplicate("a", 25))
      assert {:error, _} = Command.parse("/join")
    end

    test "/nick takes a nickname and keeps its case" do
      assert Command.parse("/nick Frank_99") == {:nick, "Frank_99"}
    end

    test "/nick validates the nickname" do
      assert {:error, _} = Command.parse("/nick has space")
      assert {:error, _} = Command.parse("/nick " <> String.duplicate("a", 21))
      assert {:error, _} = Command.parse("/nick")
    end

    test "simple commands, case-insensitive" do
      assert Command.parse("/leave") == :leave
      assert Command.parse("/who") == :who
      assert Command.parse("/rooms") == :rooms
      assert Command.parse("/help") == :help
      assert Command.parse("/QUIT") == :quit
    end

    test "unknown commands are errors" do
      assert {:error, message} = Command.parse("/dance")
      assert message =~ "/dance"
    end
  end

  describe "validate_nick/1" do
    test "accepts letters, numbers, - and _" do
      assert Command.validate_nick("ok-nick_1") == {:ok, "ok-nick_1"}
    end

    test "rejects nil and bad characters" do
      assert {:error, _} = Command.validate_nick(nil)
      assert {:error, _} = Command.validate_nick("<script>")
    end
  end
end
