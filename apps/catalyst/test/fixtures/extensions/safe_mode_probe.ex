defmodule Catalyst.Ext.SafeModeProbe do
  @moduledoc false

  use Catalyst.Extension

  @impl true
  def setup(_api) do
    sentinel =
      Application.get_env(:catalyst, :flex_safe_mode_sentinel) ||
        Path.join(Catalyst.Paths.home(), "safe_mode_probe_ran")

    File.mkdir_p!(Path.dirname(sentinel))
    File.write!(sentinel, "setup ran\n")
    :ok
  end
end
