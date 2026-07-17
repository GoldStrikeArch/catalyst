defmodule Catalyst.ToolsTest do
  use ExUnit.Case, async: true

  alias Catalyst.Tools.{Read, Write, Edit, Ls, Bash, Ripgrep, Fd, Sd, AstGrep}

  setup do
    tmp = Path.join(System.tmp_dir!(), "catalyst_tools_#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(tmp, "lib"))
    on_exit(fn -> File.rm_rf!(tmp) end)
    {:ok, tmp: tmp, ctx: %{cwd: tmp, call_id: "t", report: fn _ -> :ok end}}
  end

  defp text(result), do: result.content |> Enum.map(& &1.text) |> Enum.join()

  test "write then read round-trips", %{ctx: ctx} do
    Write.execute(%{"path" => "a.txt", "content" => "hello\nworld\n"}, ctx)
    assert text(Read.execute(%{"path" => "a.txt"}, ctx)) =~ "hello\nworld"
  end

  test "read honors offset and limit", %{ctx: ctx} do
    Write.execute(%{"path" => "n.txt", "content" => "1\n2\n3\n4\n5\n"}, ctx)
    out = text(Read.execute(%{"path" => "n.txt", "offset" => 2, "limit" => 2}, ctx))
    assert out == "2\n3"
  end

  test "read raises on a missing file", %{ctx: ctx} do
    assert_raise File.Error, fn -> Read.execute(%{"path" => "nope.txt"}, ctx) end
  end

  test "ls suffixes directories", %{ctx: ctx} do
    Write.execute(%{"path" => "lib/x.ex", "content" => "x"}, ctx)
    out = text(Ls.execute(%{}, ctx))
    assert out =~ "lib/"
  end

  test "edit replaces unique text and rejects ambiguous/missing", %{ctx: ctx} do
    Write.execute(%{"path" => "e.txt", "content" => "foo bar foo"}, ctx)

    assert_raise RuntimeError, ~r/unique/, fn ->
      Edit.execute(
        %{"path" => "e.txt", "edits" => [%{"oldText" => "foo", "newText" => "X"}]},
        ctx
      )
    end

    Write.execute(%{"path" => "e2.txt", "content" => "alpha beta"}, ctx)

    Edit.execute(
      %{"path" => "e2.txt", "edits" => [%{"oldText" => "alpha", "newText" => "ALPHA"}]},
      ctx
    )

    assert text(Read.execute(%{"path" => "e2.txt"}, ctx)) == "ALPHA beta"
  end

  test "grep (ripgrep) finds matches", %{ctx: ctx} do
    Write.execute(%{"path" => "notes.txt", "content" => "alpha\nbeta TODO\n"}, ctx)
    out = text(Ripgrep.execute(%{"pattern" => "TODO"}, ctx))
    assert out =~ "notes.txt:2: beta TODO"
  end

  test "find (fd) locates files by glob", %{ctx: ctx} do
    Write.execute(%{"path" => "lib/foo.ex", "content" => "x"}, ctx)
    out = text(Fd.execute(%{"pattern" => "*.ex"}, ctx))
    assert out =~ "foo.ex"
  end

  test "replace (sd) edits in place", %{ctx: ctx} do
    Write.execute(%{"path" => "r.txt", "content" => "TODO and TODO"}, ctx)

    Sd.execute(
      %{"pattern" => "TODO", "replacement" => "DONE", "path" => "r.txt", "string_mode" => true},
      ctx
    )

    assert text(Read.execute(%{"path" => "r.txt"}, ctx)) == "DONE and DONE"
  end

  test "ast_grep searches and rewrites", %{ctx: ctx} do
    Write.execute(
      %{"path" => "lib/g.ex", "content" => "defmodule G do\n  def h, do: IO.puts(\"hi\")\nend\n"},
      ctx
    )

    search =
      text(
        AstGrep.execute(
          %{"pattern" => "IO.puts($A)", "lang" => "elixir", "path" => "lib/g.ex"},
          ctx
        )
      )

    assert search =~ "lib/g.ex:2:"

    AstGrep.execute(
      %{
        "pattern" => "IO.puts($A)",
        "rewrite" => "Logger.info($A)",
        "lang" => "elixir",
        "path" => "lib/g.ex"
      },
      ctx
    )

    assert text(Read.execute(%{"path" => "lib/g.ex"}, ctx)) =~ "Logger.info(\"hi\")"
  end

  test "bash runs a command in the cwd", %{ctx: ctx} do
    Write.execute(%{"path" => "marker", "content" => "x"}, ctx)
    out = text(Bash.execute(%{"command" => "echo hello && ls"}, ctx))
    assert out =~ "hello"
    assert out =~ "marker"
  end

  test "read refuses binary files", %{tmp: tmp, ctx: ctx} do
    File.write!(Path.join(tmp, "bin.dat"), <<0, 255, 1, 2>>)

    assert_raise RuntimeError, ~r/binary file/, fn ->
      Read.execute(%{"path" => "bin.dat"}, ctx)
    end
  end

  test "read scrubs invalid UTF-8 instead of poisoning the transcript", %{tmp: tmp, ctx: ctx} do
    File.write!(Path.join(tmp, "latin.txt"), <<"caf", 233, "\n">>)
    out = text(Read.execute(%{"path" => "latin.txt"}, ctx))
    assert String.valid?(out)
    assert out =~ "caf"
  end

  test "read appends a truncation notice the model can see", %{ctx: ctx} do
    content = Enum.map_join(1..3000, "\n", &"line #{&1}")
    Write.execute(%{"path" => "big.txt", "content" => content}, ctx)

    out = text(Read.execute(%{"path" => "big.txt"}, ctx))
    assert out =~ "[output truncated: showing first 2000 of 3000 lines]"
  end

  test "bash output with invalid UTF-8 is scrubbed", %{ctx: ctx} do
    out = text(Bash.execute(%{"command" => "printf 'a\\xffb'"}, ctx))
    assert String.valid?(out)
    assert out =~ "a�b"
  end

  test "bash times out with the effective timeout and partial output", %{ctx: ctx} do
    err =
      assert_raise RuntimeError, fn ->
        Bash.execute(%{"command" => "echo started && sleep 5", "timeout" => 1}, ctx)
      end

    assert err.message =~ "timed out after 1s"
    assert err.message =~ "started"
  end

  test "edit matches all oldTexts against the original, not accumulated content", %{ctx: ctx} do
    Write.execute(%{"path" => "m.txt", "content" => "alpha beta"}, ctx)

    # Edit 1's newText introduces "beta"; under accumulated matching edit 2
    # would become ambiguous. Against the original, both apply cleanly.
    Edit.execute(
      %{
        "path" => "m.txt",
        "edits" => [
          %{"oldText" => "alpha", "newText" => "beta X"},
          %{"oldText" => "beta", "newText" => "B"}
        ]
      },
      ctx
    )

    assert text(Read.execute(%{"path" => "m.txt"}, ctx)) == "beta X B"
  end

  test "edit rejects overlapping edits", %{ctx: ctx} do
    Write.execute(%{"path" => "o.txt", "content" => "alpha beta gamma"}, ctx)

    assert_raise RuntimeError, ~r/overlap/, fn ->
      Edit.execute(
        %{
          "path" => "o.txt",
          "edits" => [
            %{"oldText" => "alpha beta", "newText" => "x"},
            %{"oldText" => "beta gamma", "newText" => "y"}
          ]
        },
        ctx
      )
    end
  end

  test "find (fd) treats a leading-dash pattern as a pattern, not flags", %{tmp: tmp, ctx: ctx} do
    File.write!(Path.join(tmp, "-dashfile.txt"), "x")
    out = text(Fd.execute(%{"pattern" => "-dash*"}, ctx))
    assert out =~ "-dashfile.txt"
  end

  test "tools expose JSON-schema parameters", _ do
    for mod <- [Read, Write, Edit, Ls, Bash, Ripgrep, Fd, Sd, AstGrep] do
      params = mod.parameters()
      assert params["type"] == "object"
      assert is_binary(mod.name())
      assert is_binary(mod.description())
    end
  end
end
