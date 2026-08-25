defmodule Catalyst.KernelBoundaryTest do
  use ExUnit.Case, async: true

  test "the headless kernel has no compiled feature application dependency" do
    applications = Application.spec(:catalyst, :applications)

    refute :catalyst_features in applications
    refute :catalyst_web_features in applications
  end
end
