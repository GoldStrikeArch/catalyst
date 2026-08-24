defmodule Catalyst.Tools.Computer.CaptureTest do
  use ExUnit.Case, async: true
  doctest Catalyst.Tools.Computer.Capture
  alias Catalyst.Tools.Computer.Capture

  describe "screencapture_argv/2" do
    test "full display" do
      assert Capture.screencapture_argv(:full, "/tmp/a.png") ==
               ["-x", "-t", "png", "/tmp/a.png"]
    end

    test "float region rounds to integers" do
      assert Capture.screencapture_argv({:region, {0.4, 10.6, 640.0, 480.0}}, "/tmp/a.png") ==
               ["-x", "-t", "png", "-R0,11,640,480", "/tmp/a.png"]
    end
  end

  describe "sips_argv/2" do
    test "default long edge" do
      assert Capture.sips_argv("/tmp/a.png") == ["-Z", "1366", "/tmp/a.png"]
    end
  end

  describe "downscale_ratio/3" do
    test "no upscale when already within bound" do
      assert Capture.downscale_ratio(1000, 700) == 1.0
    end

    test "scales by the long edge" do
      assert Capture.downscale_ratio(2732, 2048, 1366) == 0.5
    end
  end

  describe "transform identity: inverse ∘ forward" do
    test "round-trips across Retina, downscale, and a negative-origin display" do
      origins = [{0, 0}, {1440, 0}, {-1440, 0}, {-1440, -900}]
      scales = [1.0, 2.0]
      ratios = [1.0, 0.75, 0.53359375]

      for origin <- origins, backing <- scales, ratio <- ratios do
        point = Capture.to_point({321, 654}, origin, backing, ratio)
        {sx, sy} = Capture.to_pixel(point, origin, backing, ratio)
        assert_in_delta sx, 321.0, 1.0e-9
        assert_in_delta sy, 654.0, 1.0e-9
      end
    end

    test "the Retina 2× case maps device pixels to half-points" do
      # A click at screenshot px (200, 100) on a 2x display with no downscale
      # posts at point (100, 50).
      assert Capture.to_point({200, 100}, {0, 0}, 2.0, 1.0) == {100.0, 50.0}
    end

    test "a 2× display with 0.5 downscale recovers full device resolution" do
      # 200 screenshot px ÷ 0.5 = 400 device px ÷ 2 = 200 pt.
      assert Capture.to_point({200, 100}, {0, 0}, 2.0, 0.5) == {200.0, 100.0}
    end
  end
end
