defmodule CatalystDesktop do
  @moduledoc """
  Desktop shell for Catalyst.

  Wraps the `CatalystWeb` Phoenix/LiveView app in a native window via
  `elixir-desktop` (wxWidgets `wxWebView` + LiveView). The window simply points
  at the locally-served endpoint, so the LiveView WebSocket and streaming work
  over the normal channel.
  """
end
