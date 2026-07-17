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

  test "read reports an offset beyond the end of the file", %{ctx: ctx} do
    Write.execute(%{"path" => "eof.txt", "content" => "1\n2\n3\n"}, ctx)
    res = Read.execute(%{"path" => "eof.txt", "offset" => 10}, ctx)
    assert text(res) =~ "offset 10 is beyond the end of the file (3 lines)"
  end

  test "read details include whole-file line totals, not just the slice", %{ctx: ctx} do
    Write.execute(%{"path" => "whole.txt", "content" => "1\n2\n3\n4\n5\n"}, ctx)
    res = Read.execute(%{"path" => "whole.txt", "offset" => 2, "limit" => 2}, ctx)
    assert text(res) == "2\n3"
    assert res.details.file_lines == 5
    assert res.details.offset == 2
  end

  test "streamed read reports an offset beyond the end of the file", %{tmp: tmp, ctx: ctx} do
    # > 16MB forces the streamed path.
    line = String.duplicate("x", 999) <> "\n"
    File.write!(Path.join(tmp, "big_stream.txt"), String.duplicate(line, 20_000))

    res = Read.execute(%{"path" => "big_stream.txt", "offset" => 50_000}, ctx)
    assert text(res) =~ "offset 50000 is beyond the end of the file"
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

  test "replace (sd) reports when the pattern matched nothing", %{ctx: ctx} do
    Write.execute(%{"path" => "nm.txt", "content" => "alpha beta\n"}, ctx)

    res =
      Sd.execute(
        %{"pattern" => "ZZZ", "replacement" => "Y", "path" => "nm.txt", "string_mode" => true},
        ctx
      )

    assert text(res) =~ ~s(No occurrences of "ZZZ" found in)
    assert res.details.matched == false
    assert text(Read.execute(%{"path" => "nm.txt"}, ctx)) =~ "alpha beta"
  end

  test "grep and find exclude .git internals but keep other hidden files", %{tmp: tmp, ctx: ctx} do
    File.mkdir_p!(Path.join(tmp, ".git"))
    File.write!(Path.join(tmp, ".git/config"), "NEEDLE inside git\n")
    File.write!(Path.join(tmp, ".hidden.txt"), "NEEDLE hidden\n")

    grep_out = text(Ripgrep.execute(%{"pattern" => "NEEDLE"}, ctx))
    assert grep_out =~ ".hidden.txt"
    refute grep_out =~ ".git"

    find_out = text(Fd.execute(%{"pattern" => "*"}, ctx))
    assert find_out =~ ".hidden.txt"
    refute find_out =~ ".git"
  end

  test "find (fd) bounds child output but still flags the limit", %{tmp: tmp, ctx: ctx} do
    for i <- 1..5, do: File.write!(Path.join(tmp, "cap#{i}.txt"), "x")

    res = Fd.execute(%{"pattern" => "cap*.txt", "limit" => 3}, ctx)

    assert res.details.result_limit_reached
    assert res.details.result_count == 3
    assert text(res) =~ "showing first 3 results; more exist"
  end

  test "grep caps runaway search output and says so", %{tmp: tmp, ctx: ctx} do
    line = "NEEDLE " <> String.duplicate("x", 60) <> "\n"
    File.write!(Path.join(tmp, "huge.txt"), String.duplicate(line, 200_000))

    res = Ripgrep.execute(%{"pattern" => "NEEDLE", "path" => "huge.txt"}, ctx)

    assert res.details.output_capped
    assert text(res) =~ "search output capped"
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

  test "bash supports bashisms (runs real bash when available)", %{ctx: ctx} do
    out = text(Bash.execute(%{"command" => "[[ -n yes ]] && echo BASHISM_OK"}, ctx))
    assert out =~ "BASHISM_OK"
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
