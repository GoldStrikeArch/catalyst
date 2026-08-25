defmodule Catalyst.Context.Registry do
  @moduledoc """
  Compatibility surface for context overlay registration.

  Prefer `Catalyst.Context.Window` for new call sites. Kept so extension
  wiring, the extensions panel, and existing tests keep compiling.
  """

  alias Catalyst.Context.Window

  defdelegate register_policy(module), to: Window
  defdelegate register_policy(module, opts), to: Window
  defdelegate register_threshold(model_key, value), to: Window
  defdelegate register_threshold(model_key, value, opts), to: Window
  defdelegate unregister_policy(), to: Window
  defdelegate unregister_threshold(model_key), to: Window
  defdelegate policy(), to: Window
  defdelegate threshold(model), to: Window, as: :overlay_threshold
  defdelegate register_extension_policy(api, module, opts), to: Window
  defdelegate register_extension_threshold(api, model_key, value, opts), to: Window
end
