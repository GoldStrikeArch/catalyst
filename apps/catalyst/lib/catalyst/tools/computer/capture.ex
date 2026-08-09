defmodule Catalyst.Tools.Computer.Capture do
  @moduledoc """
  Pure helpers for screen capture (plan §4): building `screencapture` / `sips`
  argv, computing the downscale ratio, and the coordinate-space transforms.

  ## The three coordinate spaces

  There are **three** spaces, not two, and conflating them is the classic silent
  2× bug:

    1. **Screenshot pixels** — what `screencapture` yields, then downscaled by
       `sips`. Top-left origin, relative to the captured image.
    2. **Device pixels** — the display's backing store (2× on Retina).
    3. **Display points** — what `CGDisplayBounds` reports and what
       `CGEventCreateMouseEvent` / `CGEventPost` expect. A non-main display's
       origin is nonzero and may be negative.

  The forward transform (a coordinate the model gave us, in the downscaled
  screenshot, → a global point to post) is:

      screenshot px ÷ downscale_ratio ÷ backing_scale + display_origin → point

  where `downscale_ratio = downscaled_long_edge / captured_long_edge ≤ 1.0`.
  `to_point/4` and its inverse `to_pixel/4` implement exactly that, taking the
  display origin (points), backing scale, and downscale ratio explicitly.
  """

  @default_long_edge 1366

  @typedoc """
  A capture target:

    * `:full` — the whole main display,
    * `{:display, index}` — `screencapture -D<index>` (1-based per `screencapture`),
    * `{:window, id}` — `screencapture -l<window_id>`,
    * `{:region, {x, y, w, h}}` — `screencapture -R x,y,w,h` (points).
  """
  @type target ::
          :full
          | {:display, non_neg_integer()}
          | {:window, non_neg_integer()}
          | {:region, {number(), number(), number(), number()}}

  @doc """
  Build the `screencapture` argv for a target, writing PNG to `path`.

  Always includes `-x` (silent, no sound) and `-t png`.

  ## Examples

      iex> Catalyst.Tools.Computer.Capture.screencapture_argv(:full, "/tmp/s.png")
      ["-x", "-t", "png", "/tmp/s.png"]

      iex> Catalyst.Tools.Computer.Capture.screencapture_argv({:display, 2}, "/tmp/s.png")
      ["-x", "-t", "png", "-D2", "/tmp/s.png"]

      iex> Catalyst.Tools.Computer.Capture.screencapture_argv({:window, 91}, "/tmp/s.png")
      ["-x", "-t", "png", "-o", "-l91", "/tmp/s.png"]

      iex> Catalyst.Tools.Computer.Capture.screencapture_argv({:region, {0, 10, 640, 480}}, "/tmp/s.png")
      ["-x", "-t", "png", "-R0,10,640,480", "/tmp/s.png"]
  """
  @spec screencapture_argv(target(), String.t()) :: [String.t()]
  def screencapture_argv(target, path) when is_binary(path) do
    ["-x", "-t", "png"] ++ target_flags(target) ++ [path]
  end

  defp target_flags(:full), do: []
  defp target_flags({:display, index}), do: ["-D#{index}"]
  # -o excludes the drop shadow: with it, the captured image corresponds
  # exactly to the window's bounds, which is what the px→point transform
  # records as the capture origin.
  defp target_flags({:window, id}), do: ["-o", "-l#{id}"]

  defp target_flags({:region, {x, y, w, h}}),
    do: ["-R#{fmt(x)},#{fmt(y)},#{fmt(w)},#{fmt(h)}"]

  # `screencapture -R` and `sips -Z` want plain integers where possible.
  defp fmt(n) when is_integer(n), do: Integer.to_string(n)
  defp fmt(n) when is_float(n), do: n |> round() |> Integer.to_string()

  @doc """
  Build the `sips` argv to downscale an image in place to a long edge of
  `long_edge` (default #{@default_long_edge}). `-Z` fits the image within the
  bound while preserving aspect ratio and never upscales.

  ## Examples

      iex> Catalyst.Tools.Computer.Capture.sips_argv("/tmp/s.png")
      ["-Z", "1366", "/tmp/s.png"]

      iex> Catalyst.Tools.Computer.Capture.sips_argv("/tmp/s.png", 1024)
      ["-Z", "1024", "/tmp/s.png"]
  """
  @spec sips_argv(String.t(), pos_integer()) :: [String.t()]
  def sips_argv(path, long_edge \\ @default_long_edge)
      when is_binary(path) and is_integer(long_edge) and long_edge > 0 do
    ["-Z", Integer.to_string(long_edge), path]
  end

  @doc """
  Compute the downscale ratio applied by `sips -Z long_edge` given the captured
  pixel dimensions. The ratio is `long_edge / max(w, h)` capped at `1.0` (an
  image already within the bound is not upscaled).

  ## Examples

      iex> Catalyst.Tools.Computer.Capture.downscale_ratio(2560, 1440)
      0.53359375

      iex> Catalyst.Tools.Computer.Capture.downscale_ratio(800, 600)
      1.0

      iex> Catalyst.Tools.Computer.Capture.downscale_ratio(2732, 2048, 1366)
      0.5
  """
  @spec downscale_ratio(pos_integer(), pos_integer(), pos_integer()) :: float()
  def downscale_ratio(width, height, long_edge \\ @default_long_edge)
      when width > 0 and height > 0 and long_edge > 0 do
    long = max(width, height)

    case long <= long_edge do
      true -> 1.0
      false -> long_edge / long
    end
  end

  @doc """
  Forward transform: a screenshot-pixel coordinate `{sx, sy}` (in the downscaled
  image) → a global display **point** suitable for `CGEventPost`.

      point = origin + (px ÷ downscale_ratio) ÷ backing_scale

  `origin` is the display's top-left in points (`{ox, oy}`, possibly negative on
  a secondary display), `backing_scale` is the Retina factor (e.g. `2.0`), and
  `downscale_ratio` comes from `downscale_ratio/3`.

  ## Examples

      # Retina 2×, no downscale, main display at origin: 200px → 100pt
      iex> Catalyst.Tools.Computer.Capture.to_point({200, 100}, {0, 0}, 2.0, 1.0)
      {100.0, 50.0}

      # Retina 2× with a 0.5 downscale: 200 screenshot px → 400 device px → 200 pt
      iex> Catalyst.Tools.Computer.Capture.to_point({200, 100}, {0, 0}, 2.0, 0.5)
      {200.0, 100.0}

      # Secondary display with a negative origin (to the left of main)
      iex> Catalyst.Tools.Computer.Capture.to_point({100, 100}, {-1440, 0}, 2.0, 1.0)
      {-1390.0, 50.0}
  """
  @spec to_point({number(), number()}, {number(), number()}, number(), number()) ::
          {float(), float()}
  def to_point({sx, sy}, {ox, oy}, backing_scale, downscale_ratio)
      when backing_scale > 0 and downscale_ratio > 0 do
    {
      ox + sx / downscale_ratio / backing_scale,
      oy + sy / downscale_ratio / backing_scale
    }
  end

  @doc """
  Inverse transform: a global display **point** `{gx, gy}` → the screenshot-pixel
  coordinate in the downscaled image. The exact inverse of `to_point/4`.

      px = (point − origin) × backing_scale × downscale_ratio

  ## Examples

      iex> Catalyst.Tools.Computer.Capture.to_pixel({100, 50}, {0, 0}, 2.0, 1.0)
      {200.0, 100.0}

      iex> Catalyst.Tools.Computer.Capture.to_pixel({-1390, 50}, {-1440, 0}, 2.0, 1.0)
      {100.0, 100.0}
  """
  @spec to_pixel({number(), number()}, {number(), number()}, number(), number()) ::
          {float(), float()}
  def to_pixel({gx, gy}, {ox, oy}, backing_scale, downscale_ratio)
      when backing_scale > 0 and downscale_ratio > 0 do
    {
      (gx - ox) * backing_scale * downscale_ratio,
      (gy - oy) * backing_scale * downscale_ratio
    }
  end

  @doc """
  Read the pixel dimensions from a PNG binary's IHDR chunk (the first chunk of
  every valid PNG). Pure; used to compute the downscale ratio without shelling
  out.

  ## Examples

      iex> png = <<0x89, "PNG", 0x0D, 0x0A, 0x1A, 0x0A, 13::32, "IHDR",
      ...>         640::32, 480::32, 8, 6, 0, 0, 0>>
      iex> Catalyst.Tools.Computer.Capture.png_dimensions(png)
      {:ok, {640, 480}}

      iex> Catalyst.Tools.Computer.Capture.png_dimensions(<<"not a png">>)
      :error
  """
  @spec png_dimensions(binary()) :: {:ok, {pos_integer(), pos_integer()}} | :error
  def png_dimensions(
        <<0x89, "PNG", 0x0D, 0x0A, 0x1A, 0x0A, _length::32, "IHDR", width::32, height::32,
          _rest::binary>>
      )
      when width > 0 and height > 0,
      do: {:ok, {width, height}}

  def png_dimensions(_other), do: :error

  @doc "The default downscale long edge (#{@default_long_edge}px)."
  @spec default_long_edge() :: pos_integer()
  def default_long_edge, do: @default_long_edge
end
