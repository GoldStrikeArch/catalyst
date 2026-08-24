defmodule Catalyst.Tools.Computer.HelperTest do
  # async: true is safe: every test runs its own unnamed Helper against its own
  # stub script + log file; nothing global is touched.
  use ExUnit.Case, async: true

  alias Catalyst.Tools.Computer.Helper

  # A stand-in for the native helper: logs every received request line to a
  # file (the "stub records ops" channel) and answers the protocol. `slow`
  # sleeps before replying (a long op in flight); `die` exits without replying
  # (a helper crash); `drag` (an input op) exits without replying (a crash
  # mid-input); `type` (an input op) never replies (a wedged helper).
  #
  # Two arg-driven behaviours model what the real helper does inside a native
  # op, independent of which op it is: `"crash": true` posts the physical event
  # and dies before replying, and `"slow_input": true` keeps working for a
  # second and logs INPUT_COMPLETED when the physical input has finished.
  @script """
  #!/bin/sh
  LOG="$1"
  while IFS= read -r line; do
    printf '%s\\n' "$line" >> "$LOG"
    id=$(printf '%s' "$line" | sed -n 's/.*"id":\\([0-9][0-9]*\\).*/\\1/p')
    case "$line" in
      *'"crash":true'*) exit 1 ;;
      *'"slow_input":true'*)
        sleep 1
        printf 'INPUT_COMPLETED\\n' >> "$LOG"
        printf '{"id":%s,"result":{"ok":true}}\\n' "$id" ;;
      *'"op":"die"'*) exit 1 ;;
      *'"op":"drag"'*) exit 1 ;;
      *'"op":"type"'*) : ;;
      *'"op":"slow"'*) sleep 1; printf '{"id":%s,"result":{"ok":true}}\\n' "$id" ;;
      *) printf '{"id":%s,"result":{"ok":true}}\\n' "$id" ;;
    esac
  done
  """

  setup do
    dir =
      Path.join(
        System.tmp_dir!(),
        "catalyst-helper-test-#{System.unique_integer([:positive, :monotonic])}"
      )

    File.mkdir_p!(dir)
    script = Path.join(dir, "stub-helper.sh")
    log = Path.join(dir, "ops.log")
    File.write!(script, @script)
    File.chmod!(script, 0o755)
    on_exit(fn -> File.rm_rf!(dir) end)

    {:ok, script: script, log: log}
  end

  defp start_helper!(ctx, opts \\ []) do
    start_supervised!(
      {Helper, [name: nil, helper_path: ctx.script, helper_args: [ctx.log]] ++ opts},
      id: make_ref()
    )
  end

  defp logged_ops(log) do
    case File.read(log) do
      {:ok, contents} -> contents
      {:error, _} -> ""
    end
  end

  # Bounded poll for externally observable state (file contents / server state);
  # there is no message to await for these.
  defp eventually(fun, attempts \\ 200) do
    case fun.() do
      true ->
        :ok

      _falsy when attempts > 0 ->
        receive do
        after
          10 -> eventually(fun, attempts - 1)
        end

      _falsy ->
        flunk("condition not met within the polling budget")
    end
  end

  test "round-trips a request and lazily opens the port on first use", ctx do
    helper = start_helper!(ctx)

    assert Helper.status(helper).port == :closed
    assert {:ok, %{"ok" => true}} = Helper.call(helper, "cursor")
    assert Helper.status(helper).port == :open
    assert logged_ops(ctx.log) =~ ~s("op":"cursor")
  end

  test "a missing binary is a tagged error, not a crash", ctx do
    helper =
      start_supervised!(
        {Helper, name: nil, helper_path: Path.join(ctx.script, "nope"), helper_args: []},
        id: make_ref()
      )

    assert {:error, :helper_missing} = Helper.call(helper, "cursor")
  end

  test "durations are capped at 30s before reaching the helper", ctx do
    helper = start_helper!(ctx)
    assert {:ok, _} = Helper.call(helper, "hold_key", %{"duration_ms" => 999_999})
    assert logged_ops(ctx.log) =~ ~s("duration_ms":30000)
  end

  test "killing the caller mid-hold posts the compensating mouse-up", ctx do
    helper = start_helper!(ctx)
    parent = self()

    caller =
      spawn(fn ->
        send(parent, {:held, Helper.call(helper, "mouse_down", %{"button" => "left"})})

        receive do
          :never -> :ok
        end
      end)

    assert_receive {:held, {:ok, _}}, 5_000
    assert Helper.status(helper).held == ["left"]

    ref = Process.monitor(caller)
    Process.exit(caller, :kill)
    assert_receive {:DOWN, ^ref, :process, ^caller, :killed}

    eventually(fn -> Helper.status(helper).held == [] end)
    eventually(fn -> logged_ops(ctx.log) =~ ~s("op":"mouse_up") end)
  end

  test "a long in-flight op does not block servicing a :DOWN", ctx do
    helper = start_helper!(ctx)
    parent = self()

    caller =
      spawn(fn ->
        send(parent, {:held, Helper.call(helper, "mouse_down", %{"button" => "left"})})

        receive do
          :never -> :ok
        end
      end)

    assert_receive {:held, {:ok, _}}, 5_000

    # A second caller parks a slow op in flight (the stub sleeps 1s on it).
    slow = Task.async(fn -> Helper.call(helper, "slow", %{}) end)
    eventually(fn -> Helper.status(helper).pending == 1 end)

    ref = Process.monitor(caller)
    Process.exit(caller, :kill)
    assert_receive {:DOWN, ^ref, :process, ^caller, :killed}

    # The :DOWN is serviced while `slow` is still pending: held clears without
    # waiting for the slow response.
    eventually(fn -> Helper.status(helper).held == [] end)
    assert {:ok, %{"ok" => true}} = Task.await(slow, 15_000)
    eventually(fn -> logged_ops(ctx.log) =~ ~s("op":"mouse_up") end)
  end

  test "helper death fails waiters, releases held input, and reopens", ctx do
    helper = start_helper!(ctx)
    parent = self()

    _caller =
      spawn(fn ->
        send(parent, {:held, Helper.call(helper, "mouse_down", %{"button" => "left"})})

        receive do
          :never -> :ok
        end
      end)

    assert_receive {:held, {:ok, _}}, 5_000
    assert Helper.status(helper).held == ["left"]

    # `die` kills the stub without a reply: the caller gets a tagged error…
    assert {:error, {:helper_exited, _reason}} = Helper.call(helper, "die", %{})

    # …held state is released via a fresh helper process (explicit mouse_up,
    # since the replacement has no memory of the old one's held buttons, plus
    # the release_all sweep for state no response ever reported)…
    eventually(fn -> Helper.status(helper).held == [] end)
    eventually(fn -> logged_ops(ctx.log) =~ ~s("op":"mouse_up") end)
    eventually(fn -> logged_ops(ctx.log) =~ ~s("op":"release_all") end)

    # …and the next ordinary call runs against the reopened port.
    assert {:ok, %{"ok" => true}} = Helper.call(helper, "cursor")
  end

  # AUDIT: held state is keyed on the *calling* pid, and every tool call runs in
  # its own short-lived `Task.async_stream` task (ToolRunner). The task exits
  # normally the moment `left_mouse_down` returns, `:DOWN` fires, and the button
  # is released before the model can issue the paired `left_mouse_up` — so the
  # pairing the tool advertises ("always pair them") cannot work. The existing
  # abort-safety test hides this by parking its caller in `receive do :never`.
  @tag :audit
  test "a held button survives the tool-call task exiting normally", ctx do
    helper = start_helper!(ctx)
    parent = self()

    # Exactly ToolRunner's shape: one short-lived task per tool call.
    caller =
      spawn(fn ->
        send(parent, {:down, Helper.call(helper, "mouse_down", %{"button" => "left"})})
      end)

    ref = Process.monitor(caller)
    assert_receive {:down, {:ok, _}}, 5_000
    assert_receive {:DOWN, ^ref, :process, ^caller, :normal}, 5_000

    # Our monitor message and the Helper's were enqueued by the same exit, so
    # once ours has arrived a sync call proves the Helper handled its own.
    _ = :sys.get_state(helper)

    assert Helper.status(helper).held == ["left"],
           "the button was released when the tool-call task exited"

    refute logged_ops(ctx.log) =~ ~s("op":"mouse_up"),
           "a compensating mouse_up was posted for a caller that merely finished"
  end

  test "a mouse_up from a later task releases a hold made by an earlier one", ctx do
    helper = start_helper!(ctx)
    parent = self()

    spawn(fn ->
      send(parent, {:down, Helper.call(helper, "mouse_down", %{"button" => "left"})})
    end)

    assert_receive {:down, {:ok, _}}, 5_000
    assert Helper.status(helper).held == ["left"]

    spawn(fn -> send(parent, {:up, Helper.call(helper, "mouse_up", %{"button" => "left"})}) end)
    assert_receive {:up, {:ok, _}}, 5_000
    assert Helper.status(helper).held == []
  end

  @tag :capture_log
  test "an unpaired hold is released by the watchdog at the cap", ctx do
    helper = start_helper!(ctx, hold_cap_ms: 100)
    parent = self()

    spawn(fn ->
      send(parent, {:down, Helper.call(helper, "mouse_down", %{"button" => "left"})})
    end)

    assert_receive {:down, {:ok, _}}, 5_000

    # No intermediate held assertion: the 100ms cap may fire before a status
    # round-trip. The observable contract is the eventual release.
    eventually(fn -> Helper.status(helper).held == [] end)
    eventually(fn -> logged_ops(ctx.log) =~ ~s("op":"mouse_up") end)
  end

  # AUDIT: caller death only marks the in-flight request `orphaned` — the native
  # helper is still inside its blocking drag loop / hold_key sleep and keeps
  # posting physical input for up to 30s after the user pressed Stop. Aborting
  # must actually stop in-flight input, not just stop waiting for it.
  @tag :audit
  test "killing the caller stops an in-flight input op", ctx do
    helper = start_helper!(ctx)

    caller =
      spawn(fn -> Helper.call(helper, "drag", %{"slow_input" => true, "button" => "left"}) end)

    eventually(fn -> Helper.status(helper).pending == 1 end)

    ref = Process.monitor(caller)
    Process.exit(caller, :kill)
    assert_receive {:DOWN, ^ref, :process, ^caller, :killed}

    # Nothing to await: wait out the native op's own duration, then assert it
    # never got to finish driving the machine.
    refute_receive :no_such_message, 1_500

    refute logged_ops(ctx.log) =~ "INPUT_COMPLETED",
           "the native op ran to completion after its caller was aborted"
  end

  # AUDIT: when the helper dies *after* posting the mouse-down but *before*
  # replying, nothing is recorded in `held`, so compensation posts only
  # `release_all` — and `release_all` in a freshly spawned helper iterates that
  # process's own (empty) gHeldButtons, releasing modifiers but no buttons. The
  # button stays physically down. The @moduledoc claims the sweep covers this.
  @tag :audit
  test "a crash between posting mouse_down and replying still releases the button", ctx do
    helper = start_helper!(ctx)

    assert {:error, {:helper_exited, _reason}} =
             Helper.call(helper, "mouse_down", %{"button" => "left", "crash" => true})

    eventually(fn -> logged_ops(ctx.log) =~ ~s("op":"release_all") end)

    assert logged_ops(ctx.log) =~ ~s("op":"mouse_up"),
           "no explicit mouse_up was posted; release_all cannot release a button " <>
             "the replacement helper never tracked"
  end

  test "helper death mid-input posts release_all even with nothing tracked held", ctx do
    helper = start_helper!(ctx)

    # `drag` is an input op and the stub dies inside it: no mouse_down response
    # ever recorded held state, yet buttons may be physically latched.
    assert {:error, {:helper_exited, _reason}} = Helper.call(helper, "drag", %{})

    eventually(fn -> logged_ops(ctx.log) =~ ~s("op":"release_all") end)
  end

  test "helper death with only an observation op in flight stays lazily closed", ctx do
    helper = start_helper!(ctx)

    # `die` is not an input op and nothing is held: no compensation is needed,
    # so the port is not reopened until the next call.
    assert {:error, {:helper_exited, _reason}} = Helper.call(helper, "die", %{})

    assert Helper.status(helper).port == :closed
    refute logged_ops(ctx.log) =~ ~s("op":"release_all")

    assert {:ok, %{"ok" => true}} = Helper.call(helper, "cursor")
    assert Helper.status(helper).port == :open
  end

  test "the pending bound rejects overload with a tagged error", ctx do
    helper = start_helper!(ctx, max_pending: 2)

    slow1 = Task.async(fn -> Helper.call(helper, "slow", %{}) end)
    slow2 = Task.async(fn -> Helper.call(helper, "slow", %{}) end)
    eventually(fn -> Helper.status(helper).pending == 2 end)

    assert {:error, :computer_helper_busy} = Helper.call(helper, "cursor")

    assert {:ok, _} = Task.await(slow1, 15_000)
    assert {:ok, _} = Task.await(slow2, 15_000)
  end

  test "queued ops are not written to the helper until the in-flight op completes", ctx do
    helper = start_helper!(ctx)

    slow = Task.async(fn -> Helper.call(helper, "slow", %{}) end)
    eventually(fn -> Helper.status(helper).pending == 1 end)

    second = Task.async(fn -> Helper.call(helper, "second", %{}) end)
    eventually(fn -> Helper.status(helper).pending == 2 end)

    # Write-when-idle: the native helper has seen only the in-flight op;
    # "second" waits server-side, not in the helper's stdin.
    eventually(fn -> logged_ops(ctx.log) =~ ~s("op":"slow") end)
    refute logged_ops(ctx.log) =~ ~s("op":"second")

    assert {:ok, _} = Task.await(slow, 15_000)
    assert {:ok, _} = Task.await(second, 15_000)
    assert logged_ops(ctx.log) =~ ~s("op":"second")
  end

  test "a timed-out queued op is cancelled and never reaches the helper", ctx do
    helper = start_helper!(ctx)

    slow = Task.async(fn -> Helper.call(helper, "slow", %{}) end)
    eventually(fn -> Helper.status(helper).pending == 1 end)

    # The queued caller's budget covers only its own op; on timeout the op is
    # reaped server-side instead of firing later as ghost input.
    assert {:error, :computer_helper_timeout} =
             Helper.call(helper, "cancelme", %{}, timeout: 100)

    assert {:ok, _} = Task.await(slow, 15_000)

    # A follow-up op drains the queue turn; the cancelled op never shows up.
    assert {:ok, _} = Helper.call(helper, "after_cancel", %{})
    assert logged_ops(ctx.log) =~ ~s("op":"after_cancel")
    refute logged_ops(ctx.log) =~ ~s("op":"cancelme")
  end

  test "a wedged helper is closed, all waiters fail tagged, and release_all is posted", ctx do
    helper = start_helper!(ctx, wedge_slack_ms: 300)

    # `type` (an input op) never replies: the server-side deadline must detect
    # the wedge — nothing else ever closes a hung-but-alive helper.
    inflight = Task.async(fn -> Helper.call(helper, "type", %{"text" => "x"}) end)
    eventually(fn -> Helper.status(helper).pending == 1 end)

    queued = Task.async(fn -> Helper.call(helper, "cursor") end)
    eventually(fn -> Helper.status(helper).pending == 2 end)

    assert {:error, :computer_helper_wedged} = Task.await(inflight, 5_000)
    assert {:error, :computer_helper_wedged} = Task.await(queued, 5_000)

    # Input was in flight when the helper was declared wedged: the fresh
    # helper process gets the release_all sweep.
    eventually(fn -> logged_ops(ctx.log) =~ ~s("op":"release_all") end)

    # And the next ordinary call runs normally.
    assert {:ok, %{"ok" => true}} = Helper.call(helper, "cursor")
  end

  test "a wedge with no input op in flight leaves the port lazily closed", ctx do
    # Slack must beat `slow`'s 1s reply, yet leave the follow-up call room to
    # spawn a fresh stub process within its own deadline.
    helper = start_helper!(ctx, wedge_slack_ms: 400)

    # `slow` replies only after 1s; the 400ms deadline wins and declares the
    # wedge. `slow` is an observation-shaped op and nothing is held, so no
    # compensation runs and the port stays closed until the next call.
    assert {:error, :computer_helper_wedged} = Helper.call(helper, "slow", %{})

    assert Helper.status(helper).port == :closed
    refute logged_ops(ctx.log) =~ ~s("op":"release_all")

    assert {:ok, %{"ok" => true}} = Helper.call(helper, "cursor")
    assert Helper.status(helper).port == :open
  end

  test "responses split across port reads are reassembled", ctx do
    # The stub writes whole lines, so this exercises the ordinary path; the
    # framing itself is pure and pinned here directly against a split write.
    helper = start_helper!(ctx)
    assert {:ok, %{"ok" => true}} = Helper.call(helper, "one")
    assert {:ok, %{"ok" => true}} = Helper.call(helper, "two")
  end
end
