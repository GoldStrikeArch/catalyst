defmodule CatalystWeb.Assets do
  @moduledoc """
  Runtime rebuild of the front-end assets (tailwind + esbuild) so an agent/extension
  can change CSS or add a JS hook and apply it without rebuilding the app — provided
  the toolchain is bundled (see E6 packaging). Builds publish a digest-addressed
  generation below `Catalyst.Paths.runtime_assets/0`; the application bundle remains
  unchanged. After a successful rebuild,
  `reload/0` tells connected clients to do a full reload so the new
  `app.js`/`app.css` are fetched.

  Degrades gracefully: if the esbuild/tailwind runtime isn't available (e.g. a
  build that didn't bundle it), `rebuild/0` returns `{:error, {:unavailable, _}}`
  instead of crashing.
  """

  require Logger

  alias CatalystWeb.RuntimeAssets

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
    case RuntimeAssets.rebuild(&build_generation/2) do
      {:ok, %{build: warnings}} ->
        reload()
        rebuilt(warnings)

      {:error, _reason} = error ->
        error
    end
  end

  defp build_generation(source, output) do
    warnings = localization_warnings(source.css)

    with :ok <- run(Tailwind, @profile, source.tailwind_cd, output),
         :ok <- run(Esbuild, @profile, source.esbuild_cd, output) do
      {:ok, warnings}
    end
  end

  defp localization_warnings(css_path) do
    case localize_extension_source(css_path) do
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
  Rewrite the editable app.css `@source` line that points at the extensions dir.

  The release seed contains the BUILD machine's `~/.catalyst/extensions` path,
  so on another user's machine tailwind would scan a path that doesn't exist.
  This rewrites the marked line in the writable copy for the machine we're
  actually running on; `rebuild/0` calls it before
  invoking tailwind. Best effort: a missing profile config, css file, or marker
  (dev, partial bundle) is a no-op — the dev css has no marker, so dev source
  is never touched. Returns `:ok` (or a `File.write/2` error tuple).
  """
  @spec localize_extension_source() :: :ok | {:error, term()}
  def localize_extension_source do
    case tailwind_input_path() do
      {:ok, css_path} -> localize_extension_source(css_path)
      :error -> :ok
    end
  end

  @doc false
  @spec localize_extension_source(Path.t()) :: :ok | {:error, term()}
  def localize_extension_source(css_path) do
    with {:ok, css} <- File.read(css_path) do
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

  @doc "URL of the active CSS generation, falling back to the packaged asset."
  @spec css_path() :: String.t()
  def css_path, do: RuntimeAssets.asset_url("assets/css/app.css", "/assets/css/app.css")

  @doc "URL of the active JavaScript generation, falling back to the packaged asset."
  @spec js_path() :: String.t()
  def js_path, do: RuntimeAssets.asset_url("assets/js/app.js", "/assets/js/app.js")

  defp run(mod, profile, cd, output) do
    cond do
      not Code.ensure_loaded?(mod) ->
        {:error, {:unavailable, mod}}

      not function_exported?(mod, :bin_path, 0) ->
        {:error, {:unavailable, mod}}

      true ->
        run_command(mod, profile, cd, output)
    end
  end

  defp run_command(mod, profile, cd, output) do
    config = Application.get_env(profile_app(mod), profile, [])
    args = output_args(mod, config[:args] || [], output)
    env = config |> Keyword.get(:env, %{}) |> normalize_env()

    try do
      case System.cmd(mod.bin_path(), args,
             cd: cd,
             env: env,
             into: IO.stream(:stdio, :line),
             stderr_to_stdout: true
           ) do
        {_output, 0} -> :ok
        {_output, status} -> {:error, {:build_failed, mod, status}}
      end
    rescue
      error -> {:error, {:build_error, mod, Exception.message(error)}}
    end
  end

  defp output_args(Tailwind, args, output),
    do: replace_arg(args, "--output=", "--output=#{Path.join(output, "assets/css/app.css")}")

  defp output_args(Esbuild, args, output),
    do: replace_arg(args, "--outdir=", "--outdir=#{Path.join(output, "assets/js")}")

  defp replace_arg(args, prefix, replacement) do
    case Enum.any?(args, &String.starts_with?(&1, prefix)) do
      true ->
        Enum.map(args, fn arg ->
          if String.starts_with?(arg, prefix), do: replacement, else: arg
        end)

      false ->
        args ++ [replacement]
    end
  end

  defp profile_app(Tailwind), do: :tailwind
  defp profile_app(Esbuild), do: :esbuild

  defp normalize_env(env) do
    Map.new(env, fn
      {key, value} when is_list(value) -> {key, Enum.join(value, path_separator())}
      entry -> entry
    end)
  end

  defp path_separator do
    case :os.type() do
      {:win32, _} -> ";"
      {:unix, _} -> ":"
    end
  end
end
