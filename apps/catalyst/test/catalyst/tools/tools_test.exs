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

  test "streamed read bounds a single very long line", %{tmp: tmp, ctx: ctx} do
    File.write!(Path.join(tmp, "one_line.txt"), String.duplicate("x", 17 * 1024 * 1024))

    res = Read.execute(%{"path" => "one_line.txt"}, ctx)
    out = text(res)

    assert res.details.lines_shown == 1
    assert out =~ "[showing 1 line(s) from line 1; file is "
    assert byte_size(out) <= 60 * 1024
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

    assert res.details.limit_reached
    assert res.details.count == 3
    assert text(res) =~ "showing first 3 results; more exist"
  end

  test "find (fd) reports visibly-incomplete output when the byte cap kills fd", %{
    tmp: tmp,
    ctx: ctx
  } do
    # Lower the cap through the test seam so a small tree exercises the
    # Exec kill-at-cap path; fd's real cap is 8MB.
    Application.put_env(:catalyst, :fd_max_output_bytes, 512)
    on_exit(fn -> Application.delete_env(:catalyst, :fd_max_output_bytes) end)

    for i <- 1..200 do
      File.write!(Path.join(tmp, "byte_cap_#{i}_#{String.duplicate("x", 40)}.txt"), "x")
    end

    res = Fd.execute(%{"pattern" => "byte_cap_*"}, ctx)

    assert res.details.output_capped
    assert text(res) =~ "output capped"
  end

  test "grep caps runaway search output and says so", %{tmp: tmp, ctx: ctx} do
    line = "NEEDLE " <> String.duplicate("x", 60) <> "\n"
    File.write!(Path.join(tmp, "huge.txt"), String.duplicate(line, 200_000))

    res = Ripgrep.execute(%{"pattern" => "NEEDLE", "path" => "huge.txt"}, ctx)

    assert res.details.output_capped
    assert text(res) =~ "output capped"
  end

  test "grep (ripgrep) salvages matches when some paths can't be searched", %{tmp: tmp, ctx: ctx} do
    File.write!(Path.join(tmp, "readable.txt"), "NEEDLE found\n")
    locked = Path.join(tmp, "locked")
    File.mkdir_p!(locked)
    File.chmod!(locked, 0o000)
    on_exit(fn -> File.chmod(locked, 0o755) end)

    # rg exits 2 (error) even though it found matches; the permission error
    # on stderr must become a note, not be dropped along with the matches.
    res = Ripgrep.execute(%{"pattern" => "NEEDLE"}, ctx)
    out = text(res)

    assert out =~ "readable.txt:1: NEEDLE found"
    assert out =~ "some paths could not be searched"
  end

  test "find (fd) raises instead of returning fd errors as paths", %{ctx: ctx} do
    # fd exits 1 and prints "[fd error]" lines (merged into stdout) for a
    # bad search path; with no real results that's an error, not a listing.
    err =
      assert_raise RuntimeError, ~r/fd error \(status 1\)/, fn ->
        Fd.execute(%{"pattern" => "*", "path" => "does_not_exist_xyz"}, ctx)
      end

    assert err.message =~ "[fd error]"
  end

  test "find (fd) splits fd error lines from salvageable result paths", _ do
    # A mixed errors+results run needs multiple search paths, which the tool
    # never passes — exercise the salvage split directly.
    out = "lib/a.ex\n[fd error]: Search path 'gone' is not a directory.\nlib/b.ex\n"
    {errors, results} = Fd.partition_errors(out)

    assert results == ["lib/a.ex", "lib/b.ex"]
    assert errors == ["[fd error]: Search path 'gone' is not a directory."]
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

  test "edit falls back to fuzzy matching (trailing whitespace, smart punctuation)", %{
    ctx: ctx
  } do
    # Trailing spaces and a smart quote in the file; the model supplies clean text.
    Write.execute(
      %{"path" => "fuzzy.txt", "content" => "hello world  \nit’s fine \nlast line\n"},
      ctx
    )

    res =
      Edit.execute(
        %{
          "path" => "fuzzy.txt",
          "edits" => [%{"oldText" => "hello world\nit's fine", "newText" => "greetings\nit's ok"}]
        },
        ctx
      )

    assert res.details.fuzzy
    assert res.content |> hd() |> Map.get(:text) =~ "fuzzy match"
    assert text(Read.execute(%{"path" => "fuzzy.txt"}, ctx)) =~ "greetings\nit's ok"
  end

  test "edit still fails cleanly when even fuzzy matching finds nothing", %{ctx: ctx} do
    Write.execute(%{"path" => "nofuzz.txt", "content" => "alpha beta\n"}, ctx)

    assert_raise RuntimeError, ~r/not found \(even with fuzzy matching\)/, fn ->
      Edit.execute(
        %{"path" => "nofuzz.txt", "edits" => [%{"oldText" => "gamma", "newText" => "x"}]},
        ctx
      )
    end
  end

  test "exact edits do not normalize the rest of the file", %{ctx: ctx} do
    Write.execute(%{"path" => "exact.txt", "content" => "keep’me\nchange this\n"}, ctx)

    res =
      Edit.execute(
        %{"path" => "exact.txt", "edits" => [%{"oldText" => "change this", "newText" => "done"}]},
        ctx
      )

    refute res.details.fuzzy
    # The smart quote elsewhere in the file is untouched.
    assert text(Read.execute(%{"path" => "exact.txt"}, ctx)) =~ "keep’me"
  end

  # 1x1 red-pixel PNG.
  @png_bytes Base.decode64!(
               "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=="
             )

  test "read returns an image file as an attachment content block", %{tmp: tmp, ctx: ctx} do
    File.write!(Path.join(tmp, "pixel.png"), @png_bytes)

    res = Read.execute(%{"path" => "pixel.png"}, ctx)

    assert [%Catalyst.Content.Text{text: note}, %Catalyst.Content.Image{} = img] = res.content
    assert note =~ "image/png"
    assert img.mime_type == "image/png"
    assert Base.decode64!(img.data) == @png_bytes
    assert res.details.mime_type == "image/png"
  end

  test "bash streams a throttled partial-output tail through ctx.report", %{tmp: tmp} do
    parent = self()
    ctx = %{cwd: tmp, call_id: "t", report: fn partial -> send(parent, {:partial, partial}) end}

    out = text(Bash.execute(%{"command" => "echo first; sleep 0.15; echo second"}, ctx))
    assert out =~ "first"
    assert out =~ "second"

    # The first chunk reports immediately; the second lands after the 100ms
    # throttle window, so it reports too.
    assert_receive {:partial, %{output: p1}}, 2_000
    assert p1 =~ "first"
    assert_receive {:partial, %{output: p2}}, 2_000
    assert p2 =~ "second"
  end

  test "a crashing report observer does not fail the bash command", %{tmp: tmp} do
    ctx = %{cwd: tmp, call_id: "t", report: fn _ -> raise "observer boom" end}
    out = text(Bash.execute(%{"command" => "echo resilient"}, ctx))
    assert out =~ "resilient"
  end

  test "bash caps runaway output and reports it", %{ctx: ctx} do
    # ~1KB lines; the 4MB cap in Exec.bash kills the loop long before the
    # 120s default timeout, and Truncate.tail bounds what the model sees.
    res =
      Bash.execute(
        %{"command" => "line=$(printf '%01000d' 0); while true; do echo $line; done"},
        ctx
      )

    assert res.details.output_capped
    assert text(res) =~ "output capped"
    assert byte_size(text(res)) <= 60 * 1024
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
