defmodule Catalyst.Tools.Computer.UnsupportedTest do
  use ExUnit.Case, async: true
  alias Catalyst.Tools.Computer.Unsupported

  test "every callback returns {:error, :unsupported_platform}" do
    assert Unsupported.screens() == {:error, :unsupported_platform}
    assert Unsupported.windows() == {:error, :unsupported_platform}
    assert Unsupported.cursor() == {:error, :unsupported_platform}
    assert Unsupported.input(%{op: :click}) == {:error, :unsupported_platform}
    assert Unsupported.capture(%{target: :full}) == {:error, :unsupported_platform}
    assert Unsupported.grants() == {:error, :unsupported_platform}
  end

  test "implements the Backend behaviour" do
    behaviours = Unsupported.module_info(:attributes)[:behaviour] || []
    assert Catalyst.Tools.Computer.Backend in behaviours
  end
end
