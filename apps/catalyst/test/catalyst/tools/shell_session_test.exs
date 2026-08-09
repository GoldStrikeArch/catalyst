defmodule Catalyst.Tools.ShellSessionTest do
  # async: false — flips shared :catalyst app env (idle/cap/backend keys) and
  # exercises the global shell-session registry and its concurrency cap.
  use ExUnit.Case, async: false

  import Catalyst.EnvCase, only: [put_env: 2, wait_until: 3]

  alias Catalyst.Content
  alias Catalyst.Tools.{Shell, ShellSession}
  alias Catalyst.Workflow.Support

  @sh "/bin/sh"

  setup do
    owner = "shtest-#{System.unique_integer([:positive])}"

    on_exit(fn ->
      Enum.each(Shell.list(owner), fn info -> Shell.close(info.id, owner) end)
    end)

    {:ok, owner: owner, ctx: ctx(owner)}
  end

  defp ctx(owner) do
    %{cwd: File.cwd!(), call_id: "t", report: fn _partial -> :ok end, session_id: owner}
  end

  defp text_of(%{content: content}), do: Content.text_of(content)

  defp run(args, ctx), do: ShellSession.execute(args, ctx)

  defp start_shell(ctx, extra \\ %{}) do
    args = Map.merge(%{"action" => "start", "shell" => @sh, "yield_ms" => 500}, extra)
    result = run(args, ctx)
    {result.details.shell_session_id, result}
  end

  # Accumulate output until `marker` shows up, starting from `acc` (output an
  # earlier start/write collect window already consumed) — arrival is OS
  # scheduling, so a bounded number of short collect windows replaces sleeps.
  defp read_until(id, ctx, marker, acc, attempts \\ 10)

  defp read_until(_id, _ctx, marker, acc, 0),
    do: flunk("marker #{inspect(marker)} never appeared in shell output: #{inspect(acc)}")

  defp read_until(id, ctx, marker, acc, attempts) do
    case String.contains?(acc, marker) do
      true ->
        acc

      false ->
        result = run(%{"action" => "read", "session_id" => id, "yield_ms" => 300}, ctx)
        read_until(id, ctx, marker, acc <> text_of(result), attempts - 1)
    end
  end

  test "start returns a session id and the shell's prompt appears", %{ctx: ctx} do
    {id, result} = start_shell(ctx)

    assert is_binary(id) and id != ""
    assert text_of(result) =~ "[shell session started: #{id}]"
    assert result.details.alive == true

    # /bin/sh's interactive prompt reaches the PTY master ("sh-3.2$ " on
    # macOS); collect more if the start window missed it.
    assert read_until(id, ctx, "$", text_of(result)) =~ "$"
  end

  test "write with a newline runs the command; the PTY echoes the input", %{ctx: ctx} do
    {id, _start} = start_shell(ctx)

    result =
      run(
        %{"action" => "write", "session_id" => id, "chars" => "echo hi_$((40 + 2))\n"},
        ctx
      )

    output = read_until(id, ctx, "hi_42", text_of(result))

    # Line-discipline echo: the written command itself appears in the output
    # stream (documented behavior), followed by its result.
    assert output =~ "echo hi_"
    assert output =~ "hi_42"
  end

  test "write without a newline stays pending until the newline arrives", %{ctx: ctx} do
    {id, _start} = start_shell(ctx)

    # The result ("pend_2") differs from the typed text ("pend_$((1 + 1))"),
    # so echo and execution are distinguishable in the output stream.
    typed =
      run(%{"action" => "write", "session_id" => id, "chars" => "echo pend_$((1 + 1))"}, ctx)

    read1 = read_until(id, ctx, "echo pend_", text_of(typed))
    refute read1 =~ "pend_2"

    newline = run(%{"action" => "write", "session_id" => id, "chars" => "\n"}, ctx)
    assert read_until(id, ctx, "pend_2", text_of(newline)) =~ "pend_2"
  end

  test "close terminates the server, script, and the shell it spawned", %{
    ctx: ctx,
    owner: owner
  } do
    {id, _start} = start_shell(ctx)

    assert [%{os_pid: script_pid}] = Shell.list(owner)
    assert {:ok, server} = Shell.fetch_owned(id, owner)
    {kids_out, 0} = System.cmd("pgrep", ["-P", Integer.to_string(script_pid)])
    shell_pid = kids_out |> String.trim() |> String.to_integer()

    ref = Process.monitor(server)
    result = run(%{"action" => "close", "session_id" => id}, ctx)
    assert result.details.closed == true

    assert_receive {:DOWN, ^ref, :process, ^server, {:shutdown, :closed}}, 2_000

    wait_until(fn -> not os_alive?(script_pid) end, 2_000, "script survived close")
    wait_until(fn -> not os_alive?(shell_pid) end, 2_000, "child shell survived close")
    wait_until(fn -> Shell.list(owner) == [] end, 2_000, "registry entry survived close")
  end

  test "an idle session is reaped after :shell_session_idle_ms", %{ctx: ctx, owner: owner} do
    put_env(:shell_session_idle_ms, 150)

    {id, _start} = start_shell(ctx, %{"yield_ms" => 0})
    assert {:ok, server} = Shell.fetch_owned(id, owner)
    ref = Process.monitor(server)

    assert_receive {:DOWN, ^ref, :process, ^server, {:shutdown, :idle_timeout}}, 5_000
    wait_until(fn -> Shell.list(owner) == [] end, 2_000, "idle shell stayed registered")
  end

  test "the concurrent-session cap raises a clear error", %{ctx: ctx} do
    put_env(:shell_session_max, 1)

    {_id, _start} = start_shell(ctx)

    assert_raise RuntimeError, ~r/shell session limit reached \(1/, fn ->
      start_shell(ctx)
    end
  end

  test "a shell refuses callers from a different Catalyst session", %{ctx: ctx} do
    {id, _start} = start_shell(ctx)
    intruder = ctx("shtest-intruder-#{System.unique_integer([:positive])}")

    for args <- [
          %{"action" => "write", "session_id" => id, "chars" => "whoami\n"},
          %{"action" => "read", "session_id" => id},
          %{"action" => "close", "session_id" => id}
        ] do
      assert_raise RuntimeError, ~r/belongs to a different Catalyst session/, fn ->
        run(args, intruder)
      end
    end

    # list shows only the caller's own sessions — the id never leaks.
    assert text_of(run(%{"action" => "list"}, intruder)) == "no live shell sessions"
    assert text_of(run(%{"action" => "list"}, ctx)) =~ id
  end

  test "the shell is reaped when its owning Catalyst session dies" do
    tmp = Path.join(System.tmp_dir!(), "shell_owner_#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    on_exit(fn -> File.rm_rf!(tmp) end)

    assert {:ok, %{id: session_id, pid: session_pid}} =
             Catalyst.Session.Manager.start_session(cwd: tmp)

    on_exit(fn -> Catalyst.Session.Manager.stop(session_id) end)

    ctx = ctx(session_id)
    {id, _start} = start_shell(ctx)
    assert {:ok, server} = Shell.fetch_owned(id, session_id)
    ref = Process.monitor(server)
    session_ref = Process.monitor(session_pid)

    :ok = Catalyst.Session.Manager.stop(session_id)
    assert_receive {:DOWN, ^session_ref, :process, ^session_pid, _reason}, 2_000
    assert_receive {:DOWN, ^ref, :process, ^server, {:shutdown, :owner_down}}, 2_000

    wait_until(
      fn -> Shell.list(session_id) == [] end,
      2_000,
      "shell stayed registered after its session died"
    )
  end

  test "output is bounded by max_bytes with a truncation notice", %{ctx: ctx, owner: owner} do
    {id, _start} = start_shell(ctx)

    _write =
      run(
        %{
          "action" => "write",
          "session_id" => id,
          "chars" => "i=0; while [ $i -lt 3000 ]; do echo line_$i; i=$((i + 1)); done\n",
          "yield_ms" => 0
        },
        ctx
      )

    # Let output accumulate in the server buffer first (a 0-yield write leaves
    # it unconsumed) so the bounded read deterministically has a surplus.
    wait_until(
      fn ->
        match?([%{pending_bytes: bytes}] when bytes > 8_192, Shell.list(owner))
      end,
      5_000,
      "shell output never accumulated past the read budget"
    )

    result =
      run(
        %{"action" => "read", "session_id" => id, "yield_ms" => 2_000, "max_bytes" => 2_048},
        ctx
      )

    assert result.details.bytes <= 2_048
    assert result.details.truncated == true
    assert text_of(result) =~ "[output capped; call read again for the rest]"

    # The rest stays buffered: a later read continues where this one stopped.
    assert run(%{"action" => "read", "session_id" => id, "yield_ms" => 200}, ctx).details.bytes >
             0
  end

  test "streamed chunks reach ctx.report while collecting", %{owner: owner} do
    parent = self()
    ctx = %{ctx(owner) | report: fn partial -> send(parent, {:partial, partial}) end}

    {id, _start} = start_shell(ctx)
    _write = run(%{"action" => "write", "session_id" => id, "chars" => "echo streamed\n"}, ctx)

    assert_receive {:partial, %{output: output}} when is_binary(output), 2_000
  end

  test "a written exit ends the shell and reads report the exit status", %{ctx: ctx} do
    {id, _start} = start_shell(ctx)

    result =
      run(
        %{"action" => "write", "session_id" => id, "chars" => "exit 3\n", "yield_ms" => 3_000},
        ctx
      )

    # `script` propagates its child's failure as its own nonzero exit; the
    # collect window ends early on shell exit rather than waiting out yield_ms.
    assert result.details.alive == false
    assert is_integer(result.details.exit_status)
    assert text_of(result) =~ "[shell exited with status #{result.details.exit_status}]"

    # Writing to an exited shell is a tagged failure surfaced as an error.
    assert_raise RuntimeError, ~r/has exited/, fn ->
      run(%{"action" => "write", "session_id" => id, "chars" => "echo more\n"}, ctx)
    end

    assert :ok = Shell.close(id, ctx.session_id)
  end

  test "unknown ids and missing args raise tagged tool errors", %{ctx: ctx} do
    assert_raise RuntimeError, ~r/unknown shell session/, fn ->
      run(%{"action" => "read", "session_id" => "sh-nope"}, ctx)
    end

    assert_raise RuntimeError, ~r/requires "session_id"/, fn ->
      run(%{"action" => "read"}, ctx)
    end

    assert_raise RuntimeError, ~r/requires "session_id" and "chars"/, fn ->
      run(%{"action" => "write", "session_id" => "sh-x"}, ctx)
    end
  end

  describe "capability gating" do
    setup do
      previous = Application.fetch_env(:catalyst, :computer_backend_available)

      on_exit(fn ->
        case previous do
          {:ok, value} -> Application.put_env(:catalyst, :computer_backend_available, value)
          :error -> Application.delete_env(:catalyst, :computer_backend_available)
        end
      end)

      :ok
    end

    test "shell_session is absent without the :computer_use grant" do
      Application.put_env(:catalyst, :computer_backend_available, true)
      config = %{tools: [ShellSession], tool_source: [ShellSession], opts: []}

      assert Support.resolve_tools(config) == []
      assert Support.resolve_tools(%{config | opts: [computer_use: true]}) == [ShellSession]
    end

    test "an unavailable backend keeps shell_session out even when asked for" do
      Application.put_env(:catalyst, :computer_backend_available, false)
      config = %{tools: [ShellSession], tool_source: [ShellSession], opts: [computer_use: true]}

      assert Support.resolve_tools(config) == []
    end

    test "shell_session ships in the builtin list as a sequential gated tool" do
      assert ShellSession in Catalyst.Tools.Registry.default_tools()
      assert ShellSession.execution_mode() == :sequential
      assert Catalyst.Tools.Registry.capabilities_of(ShellSession) == [:computer_use]
    end
  end

  describe "audit regressions" do
    # AUDIT: when the wrapper exits on its own, `handle_info({port, {:exit_status,
    # _}})` clears `:port` but keeps `:os_pid`. The server then lives on until the
    # 15-minute idle timeout, and `terminate/2` runs `kill_tree(state.os_pid)` —
    # `pgrep -P <pid>` plus `kill -KILL -<child>` and `kill -KILL <pid>` — against
    # a number the OS may have recycled by then. A reaped pid must not be retained
    # as a kill target.
    @tag :audit
    test "a naturally exited shell keeps no pid to kill later", %{ctx: ctx, owner: owner} do
      {id, _result} = start_shell(ctx)

      run(%{"action" => "write", "session_id" => id, "chars" => "exit\n"}, ctx)

      wait_until(
        fn -> match?(%{alive: false}, shell_info(owner, id)) end,
        5_000,
        "the shell never reported its natural exit"
      )

      info = shell_info(owner, id)

      assert info.exit_status != nil
      assert info.os_pid == nil, "a reaped os_pid is still retained as a SIGKILL target"
    end
  end

  defp shell_info(owner, id), do: Enum.find(Shell.list(owner), &(&1.id == id))

  defp os_alive?(os_pid) do
    case System.cmd("kill", ["-0", Integer.to_string(os_pid)], stderr_to_stdout: true) do
      {_out, 0} -> true
      {_out, _nonzero} -> false
    end
  end
end
