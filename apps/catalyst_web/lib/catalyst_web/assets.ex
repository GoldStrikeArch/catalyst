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

  require Logger

  @topic "ui"
  @profile :catalyst_web

  # Marks the tailwind `@source` line that points at the extensions dir in the
  # bundled app.css (written by the root mix.exs `bundle_assets` release step).
  @ext_source_marker "/* catalyst:extensions-source */"
  @ext_source_re ~r/#{Regex.escape(@ext_source_marker)}\n@source "[^"]*";/

  @doc "PubSub topic used to signal UI/asset reloads to connected LiveViews."
  @spec topic() :: String.t()
  def topic, do: @topic

  @doc """
  Rebuild CSS+JS, then ask clients to reload.

  Returns `{:ok, %{warnings: [...]}}` when the rebuild itself succeeded but
  localizing the bundled extensions `@source` line failed — tailwind then ran
  against a stale (build-machine) extensions path, so extension-added classes
  may be missing until the failure is fixed.
  """
  @spec rebuild() :: :ok | {:ok, %{warnings: [term()]}} | {:error, term()}
  def rebuild do
    warnings = localization_warnings()

    with :ok <- run(Tailwind, @profile),
         :ok <- run(Esbuild, @profile) do
      reload()
      rebuilt(warnings)
    end
  end

  defp localization_warnings do
    case localize_extension_source() do
      :ok ->
        []

      {:error, reason} ->
        Logger.warning("[assets] could not localize extensions @source: #{inspect(reason)}")
        [{:localize_extension_source, reason}]
    end
  end

  defp rebuilt([]), do: :ok
  defp rebuilt(warnings), do: {:ok, %{warnings: warnings}}

  @doc "Broadcast a reload request to every connected LiveView."
  @spec reload() :: :ok | {:error, term()}
  def reload, do: Phoenix.PubSub.broadcast(Catalyst.PubSub, @topic, :reload_assets)

  @doc """
  Rewrite the bundled app.css `@source` line that points at the extensions dir.

  The release bakes the BUILD machine's `~/.catalyst/extensions` path into the
  bundled app.css (root mix.exs `bundle_assets`), so on another user's machine
  tailwind would scan a path that doesn't exist. This rewrites the marked line
  for the machine we're actually running on; `rebuild/1` calls it before
  invoking tailwind. Best effort: a missing profile config, css file, or marker
  (dev, partial bundle) is a no-op — the dev css has no marker, so dev source
  is never touched. Returns `:ok` (or a `File.write/2` error tuple).
  """
  @spec localize_extension_source() :: :ok | {:error, term()}
  def localize_extension_source do
    with {:ok, css_path} <- tailwind_input_path(),
         {:ok, css} <- File.read(css_path) do
      line = ~s[#{@ext_source_marker}\n@source "#{Catalyst.Extensions.dir()}";]
      rewrite(css_path, css, Regex.replace(@ext_source_re, css, fn _ -> line end))
    else
      _ -> :ok
    end
  end

  defp rewrite(_path, css, css), do: :ok
  defp rewrite(path, _css, rewritten), do: File.write(path, rewritten)

  # The css entrypoint of the tailwind profile (its `:cd` + `--input=` arg).
  defp tailwind_input_path do
    config = Application.get_env(:tailwind, @profile, [])
    input = config |> Keyword.get(:args, []) |> Enum.find_value(&input_arg/1)

    case {config[:cd], input} do
      {cd, input} when is_binary(cd) and is_binary(input) -> {:ok, Path.expand(input, cd)}
      _ -> :error
    end
  end

  defp input_arg("--input=" <> path), do: path
  defp input_arg(_), do: nil

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
