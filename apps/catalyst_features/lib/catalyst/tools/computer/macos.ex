defmodule Catalyst.Tools.Computer.MacOS do
  @moduledoc """
  The macOS `Catalyst.Tools.Computer.Backend`: input, screens, windows, cursor,
  and TCC grant state go through the persistent `catalyst-input` helper
  (`Catalyst.Tools.Computer.Helper`); screen capture shells out to
  `screencapture` + `sips` via `Catalyst.Tools.Exec.collect/3` with a temp file
  under `System.tmp_dir!/0`, using the pure argv builders in
  `Catalyst.Tools.Computer.Capture`.

  Captures are **always** downscaled to a ≤#{1366}px long edge (context
  discipline, plan §5 — non-negotiable) and return the PNG binary with its
  provenance: backing `scale`, capture `origin` (points), downscale `ratio`,
  `logical_size` (points), `captured_size` (pre-downscale pixels), and `bytes`.

  All failures are tagged tuples from the helper (`:helper_missing`,
  `{:helper_exited, _}`, helper error strings) or capture
  (`{:capture_failed, out}`, `{:unknown_display, n}`, `{:unknown_window, id}`,
  `{:invalid_png, path}`).
  """

  @behaviour Catalyst.Tools.Computer.Backend

  alias Catalyst.Tools.Computer.{Capture, Helper}
  alias Catalyst.Tools.Exec

  @capture_timeout 15_000

  @impl true
  def screens do
    with {:ok, %{"screens" => screens}} when is_list(screens) <- Helper.call("screens") do
      {:ok, Enum.map(screens, &screen_from_wire/1)}
    else
      {:ok, other} -> {:error, {:malformed_helper_result, other}}
      {:error, _reason} = error -> error
    end
  end

  @impl true
  def windows do
    with {:ok, %{"windows" => windows}} when is_list(windows) <- Helper.call("windows") do
      {:ok, Enum.map(windows, &window_from_wire/1)}
    else
      {:ok, other} -> {:error, {:malformed_helper_result, other}}
      {:error, _reason} = error -> error
    end
  end

  @impl true
  def cursor do
    with {:ok, %{"x" => x, "y" => y}} <- Helper.call("cursor") do
      {:ok, %{x: x, y: y}}
    else
      {:ok, other} -> {:error, {:malformed_helper_result, other}}
      {:error, _reason} = error -> error
    end
  end

  @impl true
  def input(%{op: op} = request) when is_atom(op) do
    args =
      request
      |> Map.delete(:op)
      |> Map.new(fn {key, value} -> {to_string(key), value} end)

    Helper.call(Atom.to_string(op), args)
  end

  @impl true
  def capture(%{target: target} = request) do
    long_edge = Map.get(request, :long_edge, Capture.default_long_edge())

    with {:ok, geometry} <- target_geometry(target) do
      capture_with_geometry(target, geometry, long_edge)
    end
  end

  @impl true
  def grants do
    with {:ok, %{"trusted" => trusted}} <- Helper.call("trusted"),
         {:ok, %{"allowed" => allowed}} <- Helper.call("screen_capture_allowed") do
      {:ok, %{accessibility: trusted == true, screen_recording: allowed == true}}
    else
      {:ok, other} -> {:error, {:malformed_helper_result, other}}
      {:error, _reason} = error -> error
    end
  end

  # Screenshot readiness probed from the capture path itself: a 1×1-point
  # region capture through the exact `screencapture` invocation `capture/1`
  # uses. `grants/0` cannot answer this — the helper's
  # `CGPreflightScreenCaptureAccess()` describes the helper's own TCC subject,
  # while `screencapture` runs as a child of the BEAM (a different subject),
  # so the helper can hold the grant while every real capture silently yields
  # a bare desktop. The probe is read-only and never calls a prompting TCC
  # variant; a hard capture failure maps to `{:ok, false}` rather than an
  # error because "the capture path cannot capture" is exactly the answer.
  @impl true
  def capture_grant do
    path = tmp_path()

    try do
      case run_screencapture({:region, {0, 0, 1, 1}}, path) do
        {:ok, raw} -> {:ok, match?({:ok, _size}, Capture.png_dimensions(raw))}
        {:error, {:capture_failed, _out}} -> {:ok, false}
        {:error, _reason} = error -> error
      end
    after
      File.rm(path)
    end
  end

  # ---- capture --------------------------------------------------------------

  defp capture_with_geometry(target, geometry, long_edge) do
    path = tmp_path()

    try do
      with {:ok, raw} <- run_screencapture(target, path),
           {:ok, {width, height}} <- png_size(raw, path),
           ratio = Capture.downscale_ratio(width, height, long_edge),
           {:ok, data} <- downscale(path, raw, ratio, long_edge) do
        {:ok, build_result(data, geometry, ratio, {width, height})}
      end
    after
      File.rm(path)
    end
  end

  defp run_screencapture(target, path) do
    argv = Capture.screencapture_argv(target, path)

    with {:ok, %{status: 0}} <- collect(screencapture_path(), argv),
         {:ok, raw} <- File.read(path) do
      {:ok, raw}
    else
      {:ok, %{out: out}} -> {:error, {:capture_failed, String.slice(out, 0, 300)}}
      {:error, :enoent} -> {:error, {:capture_failed, "no output file written"}}
      {:error, _reason} = error -> error
    end
  end

  defp png_size(raw, path) do
    case Capture.png_dimensions(raw) do
      {:ok, size} -> {:ok, size}
      :error -> {:error, {:invalid_png, path}}
    end
  end

  defp downscale(_path, raw, ratio, _long_edge) when ratio >= 1.0 and is_binary(raw),
    do: {:ok, raw}

  defp downscale(path, _raw, _ratio, long_edge) do
    with {:ok, %{status: 0}} <- collect(sips_path(), Capture.sips_argv(path, long_edge)),
         {:ok, data} <- File.read(path) do
      {:ok, data}
    else
      {:ok, %{out: out}} -> {:error, {:downscale_failed, String.slice(out, 0, 300)}}
      {:error, _reason} = error -> error
    end
  end

  defp build_result(data, %{origin: origin, scale: scale}, ratio, {width, height}) do
    %{
      data: data,
      mime_type: "image/png",
      scale: scale,
      origin: origin,
      ratio: ratio,
      logical_size: {width / scale, height / scale},
      captured_size: {width, height},
      bytes: byte_size(data)
    }
  end

  defp collect(exe, argv), do: Exec.collect(exe, argv, timeout: @capture_timeout)

  defp tmp_path do
    Path.join(
      System.tmp_dir!(),
      "catalyst-capture-#{System.unique_integer([:positive, :monotonic])}.png"
    )
  end

  defp screencapture_path,
    do: System.find_executable("screencapture") || "/usr/sbin/screencapture"

  defp sips_path, do: System.find_executable("sips") || "/usr/bin/sips"

  # ---- capture geometry (origin in points + backing scale per target) -------

  defp target_geometry(:full) do
    with {:ok, screens} <- screens() do
      main = Enum.find(screens, & &1.main) || List.first(screens)
      screen_geometry(main)
    end
  end

  defp target_geometry({:display, n}) when is_integer(n) do
    with {:ok, screens} <- screens() do
      case Enum.find(screens, &(&1.index == n - 1)) do
        nil -> {:error, {:unknown_display, n}}
        screen -> screen_geometry(screen)
      end
    end
  end

  defp target_geometry({:window, id}) when is_integer(id) do
    with {:ok, windows} <- windows() do
      case Enum.find(windows, &(&1.id == id)) do
        nil -> {:error, {:unknown_window, id}}
        window -> {:ok, %{origin: {window.bounds.x, window.bounds.y}, scale: scale_at(window)}}
      end
    end
  end

  defp target_geometry({:region, {x, y, _w, _h}}) do
    {:ok, %{origin: {x, y}, scale: scale_at_point(x, y)}}
  end

  defp screen_geometry(nil), do: {:error, :no_screens}

  defp screen_geometry(screen),
    do: {:ok, %{origin: {screen.bounds.x, screen.bounds.y}, scale: screen.scale}}

  defp scale_at(%{bounds: %{x: x, y: y}}), do: scale_at_point(x, y)

  defp scale_at_point(x, y) do
    case screens() do
      {:ok, screens} -> screens |> screen_containing(x, y) |> screen_scale()
      {:error, _reason} -> 2.0
    end
  end

  defp screen_containing(screens, x, y) do
    Enum.find(screens, fn %{bounds: b} ->
      x >= b.x and x < b.x + b.width and y >= b.y and y < b.y + b.height
    end) || Enum.find(screens, & &1.main) || List.first(screens)
  end

  defp screen_scale(%{scale: scale}), do: scale
  defp screen_scale(_none), do: 2.0

  # ---- wire → typed maps ----------------------------------------------------

  defp screen_from_wire(screen) do
    %{
      id: Map.get(screen, "id", 0),
      index: Map.get(screen, "index", 0),
      main: Map.get(screen, "main", false) == true,
      bounds: rect_from_wire(Map.get(screen, "bounds", %{})),
      scale: number(Map.get(screen, "scale", 1.0), 1.0)
    }
  end

  defp window_from_wire(window) do
    %{
      id: Map.get(window, "id", 0),
      pid: Map.get(window, "pid", 0),
      app: Map.get(window, "app", ""),
      title: Map.get(window, "title", ""),
      layer: Map.get(window, "layer", 0),
      bounds: rect_from_wire(Map.get(window, "bounds", %{}))
    }
  end

  defp rect_from_wire(bounds) do
    %{
      x: number(Map.get(bounds, "x", 0), 0),
      y: number(Map.get(bounds, "y", 0), 0),
      width: number(Map.get(bounds, "width", 0), 0),
      height: number(Map.get(bounds, "height", 0), 0)
    }
  end

  defp number(value, _default) when is_number(value), do: value
  defp number(_value, default), do: default
end
