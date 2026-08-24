defmodule Catalyst.Tools.ComputerToolTest do
  # async: false — swaps the global :computer_backend app env and the stub
  # recorder persistent_term.
  use ExUnit.Case, async: false

  alias Catalyst.Computer.StubBackend
  alias Catalyst.Content
  alias Catalyst.Tools.Computer
  alias Catalyst.Tools.Registry

  setup do
    previous = Application.fetch_env(:catalyst, :computer_backend)
    Application.put_env(:catalyst, :computer_backend, StubBackend)
    StubBackend.record_to(self())

    on_exit(fn ->
      StubBackend.stop_recording()

      case previous do
        {:ok, value} -> Application.put_env(:catalyst, :computer_backend, value)
        :error -> Application.delete_env(:catalyst, :computer_backend)
      end
    end)

    {:ok, ctx: tool_ctx()}
  end

  defp tool_ctx do
    %{
      cwd: File.cwd!(),
      call_id: "call-#{System.unique_integer([:positive])}",
      report: fn _partial -> :ok end,
      session_id: "computer-test-#{System.unique_integer([:positive, :monotonic])}"
    }
  end

  defp run(args, ctx), do: Computer.execute(args, ctx)

  # ---- registration ---------------------------------------------------------

  test "computer is a gated, sequential bundled tool" do
    refute Computer in Registry.default_tools()
    assert Computer in Catalyst.Extensions.tools()
    assert {:ok, entry} = Registry.fetch_entry(Catalyst.Extensions.tools(), "computer")
    assert entry.definition.capabilities == [:computer_use]
    assert entry.definition.execution_mode == :sequential
    assert entry.definition.description =~ "pixel"
    assert entry.definition.description =~ "instructions"
  end

  # ---- screenshot + viewport ------------------------------------------------

  test "screenshot returns an image block, untrusted details, and records the viewport",
       %{ctx: ctx} do
    result = run(%{"action" => "screenshot"}, ctx)

    assert [%Content.Text{}, %Content.Image{data: data, mime_type: "image/png"}] = result.content
    assert Base.decode64!(data) == <<137, 80, 78, 71, 1, 2, 3>>

    assert %{
             untrusted: true,
             bytes: 7,
             scale: 2.0,
             ratio: 0.5,
             captured_size: %{width: 2880, height: 1800}
           } = result.details

    # Default target: the main display (index 0 → screencapture -D1).
    assert_received {:computer_stub, {:screens}}
    assert_received {:computer_stub, {:capture, %{target: {:display, 1}}}}

    # The recorded viewport now drives coordinate mapping: 100px ÷ 0.5 ÷ 2.0.
    run(%{"action" => "left_click", "coordinate" => [100, 100]}, ctx)
    assert_received {:computer_stub, {:input, %{op: :click, coordinate: [100.0, 100.0]}}}
  end

  test "screenshot targets a window when window_id is given", %{ctx: ctx} do
    run(%{"action" => "screenshot", "window_id" => 42}, ctx)
    assert_received {:computer_stub, {:capture, %{target: {:window, 42}}}}
  end

  test "screenshot maps display_id to the screencapture display index", %{ctx: ctx} do
    run(%{"action" => "screenshot", "display_id" => 10}, ctx)
    assert_received {:computer_stub, {:capture, %{target: {:display, 1}}}}
  end

  test "screenshot rejects an unknown display id", %{ctx: ctx} do
    assert_raise RuntimeError, ~r/unknown_display/, fn ->
      run(%{"action" => "screenshot", "display_id" => 77}, ctx)
    end
  end

  test "region screenshots transform last-screenshot pixels to points", %{ctx: ctx} do
    run(%{"action" => "screenshot"}, ctx)
    run(%{"action" => "screenshot", "region" => [100, 100, 200, 100]}, ctx)

    assert_received {:computer_stub, {:capture, %{target: {:display, 1}}}}
    # ratio 0.5, scale 2.0: px 100 → pt 100; extent 200x100 px → 200x100 pt.
    assert_received {:computer_stub, {:capture, %{target: {:region, {x, y, w, h}}}}}
    assert_in_delta x, 100.0, 0.001
    assert_in_delta y, 100.0, 0.001
    assert_in_delta w, 200.0, 0.001
    assert_in_delta h, 100.0, 0.001
  end

  # ---- pointer actions ------------------------------------------------------

  test "pre-screenshot coordinates are refused, not guessed", %{ctx: ctx} do
    # Before any screenshot no geometry is recorded, so a coordinate has no
    # defined meaning. The old contract mapped it through a guessed
    # main-display-points viewport; the same silent fallback also fired when
    # recorded geometry was lost (restart/eviction), landing clicks through
    # the wrong transform. Missing geometry now fails closed with an error
    # telling the model to take a screenshot first.
    assert_raise RuntimeError, ~r/screenshot/i, fn ->
      run(%{"action" => "left_click", "coordinate" => [100, 100]}, ctx)
    end

    assert_raise RuntimeError, ~r/screenshot/i, fn ->
      run(%{"action" => "mouse_move", "coordinate" => [321, 43]}, ctx)
    end

    refute_received {:computer_stub, {:input, _op}}
  end

  test "post-screenshot coordinates map through the recorded geometry", %{ctx: ctx} do
    run(%{"action" => "screenshot"}, ctx)

    # Stub geometry: origin {0, 0}, scale 2.0, ratio 0.5 — px ÷ 0.5 ÷ 2.0 + 0,
    # so the mapped point is numerically equal to the pixel coordinate.
    run(%{"action" => "left_click", "coordinate" => [100, 100]}, ctx)

    assert_received {:computer_stub,
                     {:input, %{op: :click, coordinate: [x, y], button: "left", count: 1}}}

    assert_in_delta x, 100.0, 0.001
    assert_in_delta y, 100.0, 0.001

    run(%{"action" => "mouse_move", "coordinate" => [321, 43]}, ctx)
    assert_received {:computer_stub, {:input, %{op: :mouse_move, coordinate: [mx, my]}}}
    assert_in_delta mx, 321.0, 0.001
    assert_in_delta my, 43.0, 0.001
  end

  test "click variants carry button, count, and modifiers", %{ctx: ctx} do
    # Coordinate actions require a recorded screenshot viewport.
    run(%{"action" => "screenshot"}, ctx)

    run(%{"action" => "double_click", "coordinate" => [10, 10]}, ctx)
    assert_received {:computer_stub, {:input, %{op: :click, button: "left", count: 2}}}

    run(%{"action" => "triple_click", "coordinate" => [10, 10]}, ctx)
    assert_received {:computer_stub, {:input, %{op: :click, button: "left", count: 3}}}

    run(%{"action" => "right_click", "coordinate" => [10, 10]}, ctx)
    assert_received {:computer_stub, {:input, %{op: :click, button: "right", count: 1}}}

    run(%{"action" => "middle_click", "coordinate" => [10, 10], "text" => "cmd+shift"}, ctx)

    assert_received {:computer_stub,
                     {:input, %{op: :click, button: "middle", modifiers: ["command", "shift"]}}}
  end

  test "a click without a coordinate is rejected", %{ctx: ctx} do
    assert_raise RuntimeError, ~r/`coordinate`/, fn -> run(%{"action" => "left_click"}, ctx) end
  end

  test "mouse_move, mouse_down, and mouse_up post the discrete ops", %{ctx: ctx} do
    # Coordinate actions require a recorded screenshot viewport.
    run(%{"action" => "screenshot"}, ctx)

    run(%{"action" => "mouse_move", "coordinate" => [0, 0]}, ctx)
    assert_received {:computer_stub, {:input, %{op: :mouse_move, coordinate: [x, y]}}}
    assert_in_delta x, 0.0, 0.001
    assert_in_delta y, 0.0, 0.001

    run(%{"action" => "left_mouse_down", "coordinate" => [0, 0]}, ctx)
    assert_received {:computer_stub, {:input, %{op: :mouse_down, button: "left"}}}

    run(%{"action" => "left_mouse_up", "coordinate" => [0, 0]}, ctx)
    assert_received {:computer_stub, {:input, %{op: :mouse_up, button: "left"}}}
  end

  test "left_click_drag maps both endpoints and converts duration to ms", %{ctx: ctx} do
    # Coordinate actions require a recorded screenshot viewport.
    run(%{"action" => "screenshot"}, ctx)

    run(
      %{
        "action" => "left_click_drag",
        "start_coordinate" => [0, 0],
        "coordinate" => [10, 10],
        "duration" => 0.5
      },
      ctx
    )

    assert_received {:computer_stub,
                     {:input,
                      %{
                        op: :drag,
                        start_coordinate: [start_x, _],
                        coordinate: [end_x, _],
                        duration_ms: 500
                      }}}

    assert_in_delta start_x, 0.0, 0.001
    # Stub geometry (origin {0,0}, ratio 0.5, scale 2.0): px 10 → pt 10.
    assert_in_delta end_x, 10.0, 0.001
  end

  test "scroll works with and without a coordinate", %{ctx: ctx} do
    # Coordinate-less scroll targets the current cursor position — no
    # model-supplied coordinate to map, so no screenshot is required.
    run(%{"action" => "scroll", "scroll_direction" => "up", "scroll_amount" => 7}, ctx)

    assert_received {:computer_stub,
                     {:input, %{op: :scroll, scroll_direction: "up", scroll_amount: 7} = op}}

    refute Map.has_key?(op, :coordinate)

    # Scroll AT a coordinate is a coordinate action: refused pre-screenshot,
    # mapped through the recorded geometry after one.
    assert_raise RuntimeError, ~r/screenshot/i, fn ->
      run(%{"action" => "scroll", "scroll_direction" => "down", "coordinate" => [50, 50]}, ctx)
    end

    run(%{"action" => "screenshot"}, ctx)
    run(%{"action" => "scroll", "scroll_direction" => "down", "coordinate" => [50, 50]}, ctx)
    assert_received {:computer_stub, {:input, %{op: :scroll, coordinate: [_, _]}}}
  end

  # ---- keyboard actions -----------------------------------------------------

  test "key parses the chord into modifiers + key", %{ctx: ctx} do
    run(%{"action" => "key", "text" => "cmd+shift+s"}, ctx)

    assert_received {:computer_stub,
                     {:input, %{op: :key, key: "s", modifiers: ["command", "shift"]}}}
  end

  test "key rejects an unknown modifier", %{ctx: ctx} do
    assert_raise RuntimeError, ~r/unknown_modifier/, fn ->
      run(%{"action" => "key", "text" => "hyper+s"}, ctx)
    end
  end

  test "type forwards the text verbatim", %{ctx: ctx} do
    run(%{"action" => "type", "text" => "héllo 世界"}, ctx)
    assert_received {:computer_stub, {:input, %{op: :type, text: "héllo 世界"}}}
  end

  test "hold_key caps duration at 30s", %{ctx: ctx} do
    run(%{"action" => "hold_key", "text" => "a", "duration" => 999}, ctx)
    assert_received {:computer_stub, {:input, %{op: :hold_key, key: "a", duration_ms: 30_000}}}
  end

  test "wait sleeps briefly and reports the duration", %{ctx: ctx} do
    result = run(%{"action" => "wait", "duration" => 0.01}, ctx)
    assert result.details.duration_ms == 10
  end

  # ---- observation actions --------------------------------------------------

  test "a region screenshot without recorded geometry is refused", %{ctx: ctx} do
    # `region` is expressed in last-screenshot pixels, so it needs the recorded
    # geometry exactly like a click does.
    assert_raise RuntimeError, ~r/screenshot/i, fn ->
      run(%{"action" => "screenshot", "region" => [100, 100, 200, 100]}, ctx)
    end

    refute_received {:computer_stub, {:capture, _request}}
  end

  test "cursor_position without geometry reports labeled display points", %{ctx: ctx} do
    # An observation moves nothing, so it need not fail — but it must not
    # fabricate a pixel coordinate either.
    result = run(%{"action" => "cursor_position"}, ctx)

    assert result.details == %{point: %{x: 100, y: 50}}
    refute Map.has_key?(result.details, :pixel)
    assert Content.text_of(result.content) =~ "DISPLAY POINTS"
  end

  test "cursor_position reports last-screenshot pixel space", %{ctx: ctx} do
    run(%{"action" => "screenshot"}, ctx)
    result = run(%{"action" => "cursor_position"}, ctx)

    # Point {100, 50} → px: (100 − 0) × 2.0 × 0.5 = 100, (50) × 2.0 × 0.5 = 50.
    assert result.details.pixel == %{x: 100, y: 50}
    assert result.details.point == %{x: 100, y: 50}
  end

  test "list_screens and list_windows format the stub world", %{ctx: ctx} do
    screens = run(%{"action" => "list_screens"}, ctx)
    assert Content.text_of(screens.content) =~ "id=10"
    assert Content.text_of(screens.content) =~ "main"
    assert screens.details.count == 1

    windows = run(%{"action" => "list_windows"}, ctx)
    assert Content.text_of(windows.content) =~ "id=42"
    assert Content.text_of(windows.content) =~ "TestApp"
    assert windows.details.count == 1
    # Window titles are attacker-influenceable screen content (plan §6).
    assert windows.details.untrusted == true
  end

  # AUDIT: screenshots persist in the transcript, but the geometry that makes
  # their pixel coordinates meaningful lives only in a fresh ETS table — lost on
  # restart, and evicted past 64 sessions. `viewport/2` then silently falls back
  # to main-display points, so a coordinate the model read off a window-scoped
  # Retina screenshot lands somewhere else entirely. Missing geometry must fail
  # closed (or demand a fresh screenshot), not guess.
  @tag :audit
  test "a coordinate is refused when its screenshot geometry is gone", %{ctx: ctx} do
    run(%{"action" => "screenshot", "window_id" => 42}, ctx)
    assert_receive {:computer_stub, {:capture, _request}}

    # The model's coordinate is in that window screenshot's pixel space.
    with_geometry = run(%{"action" => "left_click", "coordinate" => [100, 100]}, ctx)
    assert_receive {:computer_stub, {:input, %{op: :click, coordinate: mapped}}}
    assert with_geometry.details.coordinate == [100, 100]

    # Restart / eviction: the recorded geometry is gone, the transcript is not.
    :ets.delete(:catalyst_computer_viewport, ctx.session_id)

    assert_raise RuntimeError, ~r/screenshot/i, fn ->
      run(%{"action" => "left_click", "coordinate" => [100, 100]}, ctx)
    end

    refute_receive {:computer_stub, {:input, _op}},
                   200,
                   "a click was posted against fallback geometry instead of #{inspect(mapped)}"
  end
end
