defmodule CatalystWeb.Assets do
  @moduledoc """
  Runtime rebuild of the front-end assets (tailwind + esbuild) so an agent/extension
  can change CSS or add a JS hook and apply it without rebuilding the app — provided
  the toolchain is bundled (see E6 packaging). After a successful rebuild,
  `reload/0` tells connected clients to do a full reload so the new
  `app.js`/`app.css` are fetched.

  Degrades gracefully: if the esbuild/tailwind runtime isn't available (e.g. a
  build that didn't bundle it), `rebuild/0` returns `{:error, {:unavailable, _}}`
  instead of crashing.
  """

  @topic "ui"
  @profile :catalyst_web

  @doc "PubSub topic used to signal UI/asset reloads to connected LiveViews."
  def topic, do: @topic

  @doc "Rebuild CSS+JS, then (by default) ask clients to reload."
  def rebuild(opts \\ []) do
    with :ok <- run(Tailwind, @profile),
         :ok <- run(Esbuild, @profile) do
      if Keyword.get(opts, :reload, true), do: reload()
      :ok
    end
  end

  @doc "Broadcast a reload request to every connected LiveView."
  def reload, do: Phoenix.PubSub.broadcast(Catalyst.PubSub, @topic, :reload_assets)

  defp run(mod, profile) do
    cond do
      not Code.ensure_loaded?(mod) ->
        {:error, {:unavailable, mod}}

      not function_exported?(mod, :run, 2) ->
        {:error, {:unavailable, mod}}

      true ->
        try do
          case mod.run(profile, []) do
            0 -> :ok
            status -> {:error, {:build_failed, mod, status}}
          end
        rescue
          e -> {:error, {:build_error, mod, Exception.message(e)}}
        end
    end
  end
end
