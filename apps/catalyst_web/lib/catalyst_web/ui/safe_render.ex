defmodule CatalystWeb.UI.SafeRender do
  @moduledoc """
  Forces extension-supplied render functions to iodata inside one
  rescue/catch boundary.

  Calling a `~H` component only BUILDS a lazy `%Phoenix.LiveView.Rendered{}`
  whose dynamics would otherwise run later in the diff engine, outside any
  rescue — so the template is forced to iodata INSIDE the guard here.
  raise/throw/exit (e.g. a bad assign or a GenServer call in the template) all
  fall through to the caller's fallback, which stays on the normal
  lazy/diffable path. Built-in renderers never pass through this module.
  """

  require Logger

  @doc """
  Evaluate `render` and force the result to `{:safe, iodata}`.

  On raise/throw/exit, log a warning naming `label` and return `fallback.()`
  instead.
  """
  @spec forced_iodata((-> term()), String.t(), (-> fallback)) :: {:safe, iodata()} | fallback
        when fallback: var
  def forced_iodata(render, label, fallback) do
    {:safe, Phoenix.HTML.Safe.to_iodata(render.())}
  rescue
    error ->
      Logger.warning("[ui] #{label} raised: #{Exception.message(error)} — using fallback")
      fallback.()
  catch
    kind, reason ->
      Logger.warning("[ui] #{label} #{kind}: #{inspect(reason)} — using fallback")
      fallback.()
  end
end
