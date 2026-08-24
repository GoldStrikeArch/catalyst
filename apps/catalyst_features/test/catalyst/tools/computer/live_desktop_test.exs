defmodule Catalyst.Tools.Computer.LiveDesktop do
  @moduledoc false
  # Support for the opt-in real-desktop tier (`mix test.computer`): precondition
  # probing (compile-time, so missing grants become real skips) and the owner
  # process for the helper's `--test-target` instrument window.

  alias Catalyst.Tools.Computer.Protocol

  @doc false
  def helper_bin do
    Path.join([to_string(:code.priv_dir(:catalyst)), "bin", "catalyst-input"])
  end

  @doc false
  # Whether this run actually asked for the :computer tier — probing spawns the
  # helper binary, which an ordinary `mix test` load of this file must not do.
  def tier_requested? do
    ExUnit.configuration()
    |> Keyword.get(:include, [])
    |> Enum.any?(fn
      :computer -> true
      "computer" -> true
      {:computer, _value} -> true
      _other -> false
    end)
  end

  @doc false
  # Probe the helper's read-only preflight ops (NEVER the request_* prompting
  # variants). Returns :ok or {:missing, [what]}.
  def probe_grants do
    port =
      Port.open({:spawn_executable, helper_bin()}, [:binary, :exit_status, :use_stdio, :hide])

    Port.command(port, [
      Protocol.encode(1, "trusted", %{}),
      "\n",
      Protocol.encode(2, "screen_capture_allowed", %{}),
      "\n"
    ])

    result = collect_probe(port, "", %{})

    try do
      Port.close(port)
    rescue
      ArgumentError -> :ok
    end

    case result do
      %{1 => %{"trusted" => true}, 2 => %{"allowed" => true}} ->
        :ok

      %{} = seen ->
        missing =
          [
            {get_in(seen, [1, "trusted"]) != true, "Accessibility (input posting)"},
            {get_in(seen, [2, "allowed"]) != true, "Screen Recording (capture)"}
          ]
          |> Enum.filter(&elem(&1, 0))
          |> Enum.map(&elem(&1, 1))

        {:missing, missing}
    end
  end

  defp collect_probe(_port, _buffer, seen) when map_size(seen) == 2, do: seen

  defp collect_probe(port, buffer, seen) do
    receive do
      {^port, {:data, chunk}} ->
        {lines, rest} = split_lines(buffer <> chunk)

        seen =
          Enum.reduce(lines, seen, fn line, acc ->
            case Protocol.decode_response(line) do
              {:ok, id, {:ok, result}} -> Map.put(acc, id, result)
              _other -> acc
            end
          end)

        collect_probe(port, rest, seen)

      {^port, {:exit_status, _status}} ->
        seen
    after
      5_000 -> seen
    end
  end

  defp split_lines(buffer) do
    parts = String.split(buffer, "\n")
    {lines, [rest]} = Enum.split(parts, -1)
    {Enum.reject(lines, &(&1 == "")), rest}
  end

  @doc false
  def skip_instructions(reason) do
    """

    ============================================================================
    mix test.computer — real-desktop tier SKIPPED: #{reason}

    This tier drives the REAL catalyst-input helper against its own
    --test-target window. To run it:

      1. Build the helper:            mix catalyst.computer.build
      2. Grant Accessibility to the terminal you run `mix test.computer` from:
         System Settings → Privacy & Security → Accessibility
      3. Grant Screen Recording to the same terminal:
         System Settings → Privacy & Security → Screen Recording
      4. Re-run:                      mix test.computer

    Grants attach to the TERMINAL's TCC identity under `mix test` (not to
    Catalyst.app). Never grant these on a machine you don't control.
    ============================================================================
    """
  end

  # ---- test-target ownership ------------------------------------------------

  @doc false
  # Start the --test-target window under a dedicated owner process (the Port
  # must outlive setup_all's process). Returns {:ok, owner, ready_event}.
  def start_target do
    parent = self()
    owner = spawn(fn -> target_init(parent) end)

    receive do
      {:target_ready, ^owner, ready} -> {:ok, owner, ready}
    after
      10_000 ->
        Process.exit(owner, :kill)
        {:error, :target_not_ready}
    end
  end

  @doc false
  def subscribe(owner), do: send(owner, {:subscribe, self()})

  @doc false
  def stop_target(owner) do
    ref = Process.monitor(owner)
    send(owner, :stop)

    receive do
      {:DOWN, ^ref, :process, ^owner, _reason} -> :ok
    after
      2_000 ->
        Process.exit(owner, :kill)
        :ok
    end
  end

  defp target_init(parent) do
    port =
      Port.open(
        {:spawn_executable, helper_bin()},
        [:binary, :exit_status, :use_stdio, :hide, {:args, ["--test-target"]}]
      )

    target_loop(%{port: port, buffer: "", parent: parent, subscriber: nil})
  end

  defp target_loop(state) do
    receive do
      {:subscribe, pid} ->
        target_loop(%{state | subscriber: pid})

      :stop ->
        # Closing the Port EOFs the target's stdin (it exits on that); the
        # explicit kill is belt-and-braces so a wedged target can never
        # linger on the desktop.
        os_pid =
          case Port.info(state.port, :os_pid) do
            {:os_pid, pid} -> pid
            _closed -> nil
          end

        try do
          Port.close(state.port)
        rescue
          ArgumentError -> :ok
        end

        case os_pid do
          nil -> :ok
          pid -> System.cmd("kill", ["-9", Integer.to_string(pid)], stderr_to_stdout: true)
        end

      {port, {:data, chunk}} when port == state.port ->
        {lines, buffer} = split_lines(state.buffer <> chunk)
        state = Enum.reduce(lines, %{state | buffer: buffer}, &target_line/2)
        target_loop(state)

      {port, {:exit_status, _status}} when port == state.port ->
        :ok
    end
  end

  defp target_line(line, state) do
    case Jason.decode(line) do
      {:ok, %{"event" => "ready"} = ready} ->
        send(state.parent, {:target_ready, self(), ready})
        state

      {:ok, %{"event" => _kind} = event} ->
        case state.subscriber do
          nil -> :ok
          pid -> send(pid, {:target_event, event})
        end

        state

      _other ->
        state
    end
  end
end

defmodule Catalyst.Tools.Computer.LiveDesktopTest do
  @moduledoc """
  The real-desktop proof (plan Verification, "Automated — real desktop"): every
  assertion is a full round-trip through the production input path AND the real
  window server, observed by the helper's own `--test-target` window.

  Opt-in via `mix test.computer`. When preconditions are missing (helper not
  built, or Accessibility / Screen Recording not granted to the test runner's
  TCC subject) the whole module SKIPS with one loud instruction block.
  """

  use ExUnit.Case, async: false

  alias Catalyst.Tools.Computer.{Capture, Helper, LiveDesktop, MacOS}

  @moduletag :computer
  @moduletag timeout: 120_000

  # Precondition gate, evaluated at load time so missing grants become real
  # ExUnit skips. Probing spawns the helper binary, so it only runs when the
  # :computer tier was actually requested.
  cond do
    not LiveDesktop.tier_requested?() ->
      @moduletag skip: "opt-in tier — run with `mix test.computer`"

    not File.regular?(LiveDesktop.helper_bin()) ->
      IO.puts(LiveDesktop.skip_instructions("helper binary not built"))
      @moduletag skip: "catalyst-input not built (mix catalyst.computer.build)"

    true ->
      case LiveDesktop.probe_grants() do
        :ok ->
          :ok

        {:missing, missing} ->
          IO.puts(
            LiveDesktop.skip_instructions("missing TCC grants: #{Enum.join(missing, ", ")}")
          )

          @moduletag skip: "TCC grants missing: #{Enum.join(missing, ", ")}"
      end
  end

  # Target content-view geometry (see rel/macos/computer_helper.m):
  # red pad (20,20)-(140,140), blue pad (160,20)-(280,140), text field
  # (20,160)-(420,190) — all in flipped (top-left origin) view coordinates.
  @red_center {80, 80}
  @blue_center {220, 80}
  @field_center {220, 175}

  setup_all do
    previous_path = Application.fetch_env(:catalyst, :computer_helper_path)
    previous_avail = Application.fetch_env(:catalyst, :computer_backend_available)
    Application.put_env(:catalyst, :computer_helper_path, LiveDesktop.helper_bin())
    Application.put_env(:catalyst, :computer_backend_available, true)

    on_exit(fn ->
      restore = fn key, previous ->
        case previous do
          {:ok, value} -> Application.put_env(:catalyst, key, value)
          :error -> Application.delete_env(:catalyst, key)
        end
      end

      restore.(:computer_helper_path, previous_path)
      restore.(:computer_backend_available, previous_avail)
    end)

    {:ok, owner, ready} = LiveDesktop.start_target()
    on_exit(fn -> LiveDesktop.stop_target(owner) end)

    window_id = ready["window_id"]

    # The window must be enumerable through the production windows op.
    bounds = await_window(window_id, 50)

    %{target: owner, window_id: window_id, bounds: bounds}
  end

  setup %{target: target} do
    LiveDesktop.subscribe(target)
    :ok
  end

  defp await_window(window_id, attempts) do
    case MacOS.windows() do
      {:ok, windows} ->
        case Enum.find(windows, &(&1.id == window_id)) do
          %{bounds: bounds} ->
            bounds

          nil when attempts > 0 ->
            receive do
            after
              100 -> await_window(window_id, attempts - 1)
            end

          nil ->
            flunk("test-target window #{window_id} never appeared in the windows listing")
        end

      {:error, reason} ->
        flunk("windows op failed: #{inspect(reason)}")
    end
  end

  # Click a bare corner of the window and derive the global→view-local offset,
  # so later assertions can target exact pad coordinates without hardcoding the
  # title-bar height.
  defp calibrate(bounds) do
    gx = bounds.x + bounds.width - 30
    gy = bounds.y + bounds.height - 12

    {:ok, _} = Helper.call("click", %{"coordinate" => [gx, gy], "button" => "left", "count" => 1})

    assert_receive {:target_event, %{"event" => "left_mouse_down", "x" => lx, "y" => ly}}, 10_000
    assert_receive {:target_event, %{"event" => "left_mouse_up"}}, 10_000
    {gx - lx, gy - ly}
  end

  defp global({lx, ly}, {ox, oy}), do: [ox + lx, oy + ly]

  defp drain_events do
    receive do
      {:target_event, _event} -> drain_events()
    after
      0 -> :ok
    end
  end

  test "input round-trip: clicks with counts, buttons, and modifiers land where posted",
       %{bounds: bounds} do
    offset = calibrate(bounds)

    # Single left click at the red pad center.
    {:ok, _} =
      Helper.call("click", %{
        "coordinate" => global(@red_center, offset),
        "button" => "left",
        "count" => 1
      })

    assert_receive {:target_event,
                    %{"event" => "left_mouse_down", "x" => x, "y" => y, "click_count" => 1}},
                   10_000

    assert_in_delta x, elem(@red_center, 0), 2.0
    assert_in_delta y, elem(@red_center, 1), 2.0
    assert_receive {:target_event, %{"event" => "left_mouse_up"}}, 10_000

    # Double click reaches click_count 2 at the blue pad.
    {:ok, _} =
      Helper.call("click", %{
        "coordinate" => global(@blue_center, offset),
        "button" => "left",
        "count" => 2
      })

    assert_receive {:target_event, %{"event" => "left_mouse_down", "click_count" => 2}}, 10_000
    drain_events()

    # Right and middle buttons report their own event kinds.
    {:ok, _} =
      Helper.call("click", %{"coordinate" => global(@red_center, offset), "button" => "right"})

    assert_receive {:target_event, %{"event" => "right_mouse_down"}}, 10_000

    {:ok, _} =
      Helper.call("click", %{"coordinate" => global(@red_center, offset), "button" => "middle"})

    assert_receive {:target_event, %{"event" => "middle_mouse_down"}}, 10_000
    drain_events()

    # Modifier-clicks carry their flags through the window server.
    {:ok, _} =
      Helper.call("click", %{
        "coordinate" => global(@red_center, offset),
        "button" => "left",
        "count" => 1,
        "modifiers" => ["command", "shift"]
      })

    assert_receive {:target_event, %{"event" => "left_mouse_down", "modifiers" => modifiers}},
                   10_000

    assert "command" in modifiers
    assert "shift" in modifiers
  end

  test "typing round-trip: key chords and mixed-script Unicode text", %{bounds: bounds} do
    offset = calibrate(bounds)

    # A cmd+shift chord is observed with its flags (via the target's local
    # event monitor, so first-responder state cannot swallow it). This
    # exercises the layout-aware keycode table against the REAL active layout.
    {:ok, _} = Helper.call("key", %{"key" => "s", "modifiers" => ["command", "shift"]})

    assert_receive {:target_event, %{"event" => "key_down", "modifiers" => chord_mods}}, 10_000
    assert "command" in chord_mods
    assert "shift" in chord_mods
    drain_events()

    # Focus the text field and type mixed-script Unicode; the field reports its
    # full contents through text_changed.
    {:ok, _} =
      Helper.call("click", %{"coordinate" => global(@field_center, offset), "button" => "left"})

    text = "Héllo 世界 مرحبا ok"
    {:ok, %{"length" => _}} = Helper.call("type", %{"text" => text})

    assert_eventually_text(text)
  end

  # AUDIT: `opType` chunks the string into fixed 20-UniChar (UTF-16) blocks. A
  # non-BMP character — every emoji — is a surrogate pair, so a pair straddling
  # the boundary is split across two `CGEventKeyboardSetUnicodeString` calls and
  # neither half is a valid codepoint. The chunker must not cut between a high
  # and a low surrogate.
  @tag :audit
  test "typing an emoji across the 20-unit chunk boundary", %{bounds: bounds} do
    offset = calibrate(bounds)

    {:ok, _} =
      Helper.call("click", %{"coordinate" => global(@field_center, offset), "button" => "left"})

    # 19 BMP characters put the high surrogate at index 19 and the low at 20,
    # exactly on the chunk seam.
    text = String.duplicate("a", 19) <> "🙂" <> "tail"
    {:ok, _} = Helper.call("type", %{"text" => text})

    assert_eventually_text(text)
  end

  # AUDIT: `grants/0` asks the *helper* (CGPreflightScreenCaptureAccess in the
  # helper's own process), but captures shell out to /usr/sbin/screencapture
  # from the BEAM — a different TCC subject. /computer presents the helper's
  # answer as screenshot readiness, so the page can report Screen Recording as
  # granted while every capture silently returns only the desktop picture.
  @tag :audit
  test "the reported screen-recording grant matches what the capture path can do",
       %{window_id: window_id} do
    {:ok, %{screen_recording: reported}} = MacOS.grants()
    {:ok, capture} = MacOS.capture(%{target: {:window, window_id}})

    assert reported == true
    assert capture.bytes > 0

    # Without a real grant on the *capture* path's subject, a window-scoped
    # capture comes back as the desktop picture rather than the target window,
    # and red_centroid!/1 flunks. This is the only place the two TCC subjects
    # can be compared for real; it is green only while they happen to agree.
    _centroid = red_centroid!(capture.data)
  end

  # The field reports one text_changed per committed chunk; wait for the one
  # carrying the complete string, skipping intermediates.
  defp assert_eventually_text(expected) do
    receive do
      {:target_event, %{"event" => "text_changed", "text" => ^expected}} ->
        :ok

      {:target_event, _other} ->
        assert_eventually_text(expected)
    after
      10_000 -> flunk("text field never reached #{inspect(expected)}")
    end
  end

  test "drag and scroll round-trips", %{bounds: bounds} do
    offset = calibrate(bounds)

    {:ok, _} =
      Helper.call("drag", %{
        "start_coordinate" => global(@red_center, offset),
        "coordinate" => global(@blue_center, offset),
        "duration_ms" => 300,
        "button" => "left"
      })

    assert_receive {:target_event, %{"event" => "left_mouse_down", "x" => sx, "y" => sy}}, 10_000
    assert_in_delta sx, elem(@red_center, 0), 2.0
    assert_in_delta sy, elem(@red_center, 1), 2.0

    assert_receive {:target_event, %{"event" => "drag"}}, 10_000
    assert_receive {:target_event, %{"event" => "left_mouse_up", "x" => ex, "y" => ey}}, 10_000
    assert_in_delta ex, elem(@blue_center, 0), 2.0
    assert_in_delta ey, elem(@blue_center, 1), 2.0
    drain_events()

    # Scroll over the red pad (a plain view, so the event bubbles to the
    # reporting superview) and observe a wheel delta.
    {:ok, _} =
      Helper.call("scroll", %{
        "coordinate" => global(@red_center, offset),
        "scroll_direction" => "down",
        "scroll_amount" => 3
      })

    assert_receive {:target_event, %{"event" => "scroll", "delta_y" => delta}}, 10_000
    assert delta != 0
  end

  @tag timeout: 180_000
  test "window-scoped capture + the px→point transform identity (the Retina test)",
       %{window_id: window_id} do
    {:ok, capture} = MacOS.capture(%{target: {:window, window_id}})

    assert capture.mime_type == "image/png"
    assert capture.bytes == byte_size(capture.data)
    {cw, ch} = capture.captured_size
    assert cw > 0 and ch > 0
    assert max(cw, ch) * capture.ratio <= Capture.default_long_edge() + 1

    # Find the red pad's centroid in the (downscaled) capture image, run it
    # through the production px→points transform, click there, and let the
    # target report where the click landed. Any scale/origin error lands far
    # outside the pad.
    {red_px, red_py} = red_centroid!(capture.data)

    {gx, gy} =
      Capture.to_point({red_px, red_py}, capture.origin, capture.scale, capture.ratio)

    {:ok, _} = Helper.call("click", %{"coordinate" => [gx, gy], "button" => "left", "count" => 1})

    assert_receive {:target_event, %{"event" => "left_mouse_down", "x" => lx, "y" => ly}}, 10_000
    assert lx >= 20 and lx <= 140, "click landed at local x=#{lx}, outside the red pad"
    assert ly >= 20 and ly <= 140, "click landed at local y=#{ly}, outside the red pad"
  end

  # Decode the capture (PNG → BMP via sips) and return the centroid of red-ish
  # pixels in FULL-RESOLUTION pixel coordinates of the pre-downscale image
  # (callers multiply by ratio for downscaled-space coordinates as needed).
  defp red_centroid!(png_data) do
    dir = Path.join(System.tmp_dir!(), "catalyst-live-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    png = Path.join(dir, "cap.png")
    bmp = Path.join(dir, "cap.bmp")
    File.write!(png, png_data)

    {_out, 0} =
      System.cmd("sips", ["-s", "format", "bmp", png, "--out", bmp], stderr_to_stdout: true)

    result = bmp_red_centroid(File.read!(bmp))
    File.rm_rf!(dir)

    case result do
      {:ok, centroid} -> centroid
      :error -> flunk("no red pad found in the window capture")
    end
  end

  defp bmp_red_centroid(
         <<"BM", _size::32-little, _reserved::32, offset::32-little, _hsize::32-little,
           width::32-little-signed, height::32-little-signed, _planes::16-little, bpp::16-little,
           _rest::binary>> = bmp
       )
       when bpp in [24, 32] do
    stride = div(width * div(bpp, 8) + 3, 4) * 4
    pixels = binary_part(bmp, offset, byte_size(bmp) - offset)
    bottom_up? = height > 0
    rows = abs(height)

    reds =
      for y <- 0..(rows - 1),
          x <- 0..(width - 1),
          red_at?(pixels, stride, div(bpp, 8), x, y),
          do: {x, if(bottom_up?, do: rows - 1 - y, else: y)}

    case reds do
      [] ->
        :error

      _found ->
        count = length(reds)
        {sx, sy} = Enum.reduce(reds, {0, 0}, fn {x, y}, {ax, ay} -> {ax + x, ay + y} end)
        {:ok, {sx / count, sy / count}}
    end
  end

  defp bmp_red_centroid(_other), do: :error

  defp red_at?(pixels, stride, bytes_per_px, x, y) do
    base = y * stride + x * bytes_per_px

    case binary_part(pixels, base, 3) do
      # BMP stores BGR.
      <<b, g, r>> -> r > 150 and g < 110 and b < 110
    end
  rescue
    ArgumentError -> false
  end

  test "abort safety, live: a dead caller's held button is released on screen",
       %{bounds: bounds} do
    offset = calibrate(bounds)
    coordinate = global(@red_center, offset)
    parent = self()

    caller =
      spawn(fn ->
        send(
          parent,
          {:held, Helper.call("mouse_down", %{"coordinate" => coordinate, "button" => "left"})}
        )

        receive do
          :never -> :ok
        end
      end)

    assert_receive {:held, {:ok, _}}, 10_000
    assert_receive {:target_event, %{"event" => "left_mouse_down"}}, 10_000

    ref = Process.monitor(caller)
    Process.exit(caller, :kill)
    assert_receive {:DOWN, ^ref, :process, ^caller, :killed}

    # The stub tier proves the Helper SENT the compensating up; this proves the
    # OS DELIVERED it — the target observes the physical release.
    assert_receive {:target_event, %{"event" => "left_mouse_up"}}, 10_000
  end

  test "screens, windows, and cursor sanity against the real window server",
       %{window_id: window_id, bounds: bounds} do
    {:ok, screens} = MacOS.screens()
    assert screens != []
    assert Enum.count(screens, & &1.main) == 1
    assert Enum.all?(screens, &(&1.scale >= 1.0))

    {:ok, windows} = MacOS.windows()
    target = Enum.find(windows, &(&1.id == window_id))
    assert target, "target window missing from the listing"
    assert_in_delta target.bounds.x, bounds.x, 5.0
    assert target.bounds.width >= 400

    {:ok, %{x: x, y: y}} = MacOS.cursor()
    assert is_number(x) and is_number(y)
  end
end
