defmodule CatalystWeb.RuntimeAssets do
  @moduledoc """
  Publishes runtime-built CSS, JavaScript, and runtime ESM modules outside the
  application bundle.

  Packaged releases seed a writable source workspace below `Catalyst.Paths.home/0`.
  Each successful build is installed under its content digest, then an atomic
  pointer makes the complete asset set active. Failed builds leave the previous
  generation untouched.
  """

  alias Catalyst.Files.AtomicWrite

  @digest_format ~r/^[0-9a-f]{64}$/
  @module_segment ~r/^[A-Za-z0-9][A-Za-z0-9._-]*$/
  @lock {__MODULE__, :rebuild}

  @type source :: %{
          css: Path.t(),
          esbuild_cd: Path.t(),
          root: Path.t(),
          tailwind_cd: Path.t()
        }

  @type builder :: (source(), Path.t() -> :ok | {:ok, term()} | {:error, term()})

  @doc "Writable source workspace used by packaged runtime builds."
  @spec workspace() :: Path.t()
  def workspace do
    Application.get_env(:catalyst_web, :asset_workspace, Catalyst.Paths.asset_workspace())
  end

  @doc "Root containing the current pointer and immutable generations."
  @spec root() :: Path.t()
  def root do
    Application.get_env(:catalyst_web, :runtime_assets_root, Catalyst.Paths.runtime_assets())
  end

  @doc "Ensure the editable source workspace exists and return its root directory."
  @spec ensure_workspace() :: {:ok, Path.t()} | {:error, term()}
  def ensure_workspace do
    :global.trans(@lock, fn ->
      with {:ok, source} <- source() do
        {:ok, source.root}
      end
    end)
  end

  @doc "Return the active runtime asset generation, if its directory still exists."
  @spec current_generation() :: {:ok, String.t()} | :error
  def current_generation do
    with {:ok, digest} <- read_current(),
         true <- valid_digest?(digest),
         true <- File.dir?(generation_dir(digest)) do
      {:ok, digest}
    else
      _missing_or_invalid -> :error
    end
  end

  @doc "Return a runtime-generation URL, or the packaged fallback when none is active."
  @spec asset_url(Path.t(), String.t()) :: String.t()
  def asset_url(relative, fallback) when is_binary(relative) and is_binary(fallback) do
    with {:ok, digest} <- current_generation(),
         true <- File.regular?(Path.join(generation_dir(digest), relative)) do
      "/runtime-assets/#{digest}/#{relative}"
    else
      _missing -> fallback
    end
  end

  @doc "Filesystem directory for one immutable generation."
  @spec generation_dir(String.t()) :: Path.t()
  def generation_dir(digest), do: Path.join([root(), "generations", digest])

  @doc "Return the same-origin URL for a published module in the active generation."
  @spec module_url(Path.t()) :: {:ok, String.t()} | {:error, :invalid_module_path | :not_found}
  def module_url(relative) when is_binary(relative) do
    segments = String.split(relative, "/", trim: false)

    with true <- valid_module_segments?(segments),
         {:ok, digest} <- current_generation(),
         {:ok, _file} <- module_file(digest, segments) do
      {:ok, "/runtime-assets/#{digest}/modules/#{Enum.join(segments, "/")}"}
    else
      false -> {:error, :invalid_module_path}
      :error -> {:error, :not_found}
      {:error, _reason} = error -> error
    end
  end

  @doc false
  @spec module_file(String.t(), [String.t()]) ::
          {:ok, Path.t()} | {:error, :invalid_module_path | :not_found}
  def module_file(digest, segments) do
    with true <- valid_digest?(digest),
         true <- valid_module_segments?(segments),
         root <- Path.join(generation_dir(digest), "modules"),
         {:ok, file} <- regular_descendant(root, segments) do
      {:ok, file}
    else
      false -> {:error, :invalid_module_path}
      {:error, _reason} -> {:error, :not_found}
    end
  end

  @doc false
  @spec rebuild(builder()) :: {:ok, %{generation: String.t(), build: term()}} | {:error, term()}
  def rebuild(builder) when is_function(builder, 2) do
    :global.trans(@lock, fn -> do_rebuild(builder) end)
  end

  defp do_rebuild(builder) do
    staging = staging_dir()

    try do
      with :ok <- cleanup_staging(),
           {:ok, source} <- source(),
           :ok <- File.mkdir_p(staging),
           {:ok, build_result} <- run_builder(builder, source, staging),
           {:ok, modules} <- publish_modules(source.root, staging),
           {:ok, digest} <- output_digest(staging, modules),
           :ok <- install(staging, digest),
           :ok <- activate(digest) do
        {:ok, %{generation: digest, build: build_result}}
      end
    after
      File.rm_rf(staging)
    end
  end

  defp source do
    case File.dir?(seed_workspace()) do
      true -> writable_source()
      false -> configured_source()
    end
  end

  defp writable_source do
    with :ok <- seed_writable_workspace() do
      {:ok,
       %{
         css: Path.join(workspace(), "assets/css/app.css"),
         esbuild_cd: Path.join(workspace(), "assets"),
         root: workspace(),
         tailwind_cd: workspace()
       }}
    end
  end

  defp configured_source do
    with {:ok, tailwind} <- profile(:tailwind),
         {:ok, esbuild} <- profile(:esbuild),
         {:ok, css} <- input_path(tailwind) do
      {:ok,
       %{
         css: css,
         esbuild_cd: esbuild[:cd],
         root: tailwind[:cd],
         tailwind_cd: tailwind[:cd]
       }}
    end
  end

  defp seed_writable_workspace do
    cond do
      not File.dir?(workspace()) ->
        with :ok <- copy_workspace() do
          replace_seed_baseline()
        end

      not File.dir?(seed_baseline()) ->
        adopt_unversioned_workspace()

      seed_current?() ->
        :ok

      true ->
        upgrade_workspace()
    end
  end

  defp copy_workspace do
    candidate = workspace_candidate()

    try do
      with :ok <- File.mkdir_p(Path.dirname(workspace())),
           {:ok, _files} <- File.cp_r(seed_workspace(), candidate),
           :ok <- File.rename(candidate, workspace()) do
        :ok
      else
        {:error, reason, path} -> {:error, {:asset_workspace_copy_failed, path, reason}}
        {:error, reason} -> {:error, {:asset_workspace_copy_failed, reason}}
      end
    after
      File.rm_rf(candidate)
    end
  end

  defp workspace_candidate do
    suffix = Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false)
    Path.join(Path.dirname(workspace()), ".#{Path.basename(workspace())}.#{suffix}")
  end

  defp adopt_unversioned_workspace do
    with {:ok, seed_files} <- tree_files(seed_workspace()),
         true <- seed_files_unchanged?(seed_files) do
      replace_seed_baseline()
    else
      false -> {:error, {:asset_workspace_unversioned, workspace()}}
      {:error, _reason} = error -> error
    end
  end

  defp upgrade_workspace do
    candidate = workspace_candidate()

    try do
      with {:ok, old_seed} <- tree_files(seed_baseline()),
           {:ok, new_seed} <- tree_files(seed_workspace()),
           {:ok, _files} <- File.cp_r(workspace(), candidate),
           :ok <- merge_seed_changes(candidate, old_seed, new_seed),
           :ok <- replace_workspace(candidate),
           :ok <- replace_seed_baseline() do
        :ok
      else
        {:error, reason, path} -> {:error, {:asset_workspace_upgrade_failed, path, reason}}
        {:error, _reason} = error -> error
      end
    after
      File.rm_rf(candidate)
    end
  end

  defp merge_seed_changes(candidate, old_seed, new_seed) do
    old_seed
    |> Map.keys()
    |> Kernel.++(Map.keys(new_seed))
    |> Enum.uniq()
    |> Enum.sort()
    |> Enum.reduce_while(:ok, fn relative, :ok ->
      case merge_seed_file(
             candidate,
             relative,
             Map.get(old_seed, relative),
             Map.get(new_seed, relative)
           ) do
        :ok -> {:cont, :ok}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp merge_seed_file(candidate, relative, old_content, nil) do
    path = Path.join(candidate, relative)

    case File.read(path) do
      {:ok, ^old_content} -> File.rm(path)
      {:ok, _user_content} -> :ok
      {:error, :enoent} -> :ok
      {:error, reason} -> {:error, {:asset_workspace_read_failed, relative, reason}}
    end
  end

  defp merge_seed_file(candidate, relative, nil, new_content) do
    path = Path.join(candidate, relative)

    case File.lstat(path) do
      {:error, :enoent} -> write_seed_file(path, new_content)
      {:ok, _user_file} -> :ok
      {:error, reason} -> {:error, {:asset_workspace_stat_failed, relative, reason}}
    end
  end

  defp merge_seed_file(candidate, relative, old_content, new_content) do
    path = Path.join(candidate, relative)

    case File.read(path) do
      {:ok, ^old_content} -> write_seed_file(path, new_content)
      {:ok, _user_content} -> :ok
      {:error, :enoent} -> write_seed_file(path, new_content)
      {:error, reason} -> {:error, {:asset_workspace_read_failed, relative, reason}}
    end
  end

  defp write_seed_file(path, content) do
    with :ok <- File.mkdir_p(Path.dirname(path)),
         :ok <- File.write(path, content) do
      :ok
    end
  end

  defp replace_workspace(candidate) do
    backup = workspace_candidate()

    with :ok <- File.rename(workspace(), backup) do
      case File.rename(candidate, workspace()) do
        :ok ->
          File.rm_rf(backup)
          :ok

        {:error, reason} ->
          _restore = File.rename(backup, workspace())
          {:error, {:asset_workspace_switch_failed, reason}}
      end
    end
  end

  defp replace_seed_baseline do
    candidate = seed_baseline() <> ".tmp"

    try do
      with {:ok, _removed} <- File.rm_rf(candidate),
           :ok <- File.mkdir_p(Path.dirname(seed_baseline())),
           {:ok, _files} <- File.cp_r(seed_workspace(), candidate),
           {:ok, _removed} <- File.rm_rf(seed_baseline()),
           :ok <- File.rename(candidate, seed_baseline()) do
        :ok
      else
        {:error, reason, path} -> {:error, {:asset_seed_snapshot_failed, path, reason}}
        {:error, reason} -> {:error, {:asset_seed_snapshot_failed, reason}}
      end
    after
      File.rm_rf(candidate)
    end
  end

  defp seed_current? do
    with {:ok, baseline} <- tree_files(seed_baseline()),
         {:ok, packaged} <- tree_files(seed_workspace()) do
      baseline == packaged
    else
      _error -> false
    end
  end

  defp seed_files_unchanged?(seed_files) do
    Enum.all?(seed_files, fn {relative, content} ->
      File.read(Path.join(workspace(), relative)) == {:ok, content}
    end)
  end

  defp tree_files(root), do: collect_tree_files(root, root, %{})

  defp collect_tree_files(root, directory, files) do
    case File.ls(directory) do
      {:ok, entries} ->
        entries
        |> Enum.sort()
        |> Enum.reduce_while({:ok, files}, fn entry, {:ok, acc} ->
          collect_tree_entry(root, Path.join(directory, entry), acc)
          |> then(fn
            {:ok, next} -> {:cont, {:ok, next}}
            {:error, _reason} = error -> {:halt, error}
          end)
        end)

      {:error, reason} ->
        {:error, {:asset_seed_read_failed, directory, reason}}
    end
  end

  defp collect_tree_entry(root, path, files) do
    relative = Path.relative_to(path, root)

    case File.lstat(path) do
      {:ok, %File.Stat{type: :directory}} ->
        collect_tree_files(root, path, files)

      {:ok, %File.Stat{type: :regular}} ->
        case File.read(path) do
          {:ok, content} -> {:ok, Map.put(files, relative, content)}
          {:error, reason} -> {:error, {:asset_seed_read_failed, relative, reason}}
        end

      {:ok, _unsupported} ->
        {:error, {:invalid_asset_seed_entry, relative}}

      {:error, reason} ->
        {:error, {:asset_seed_stat_failed, relative, reason}}
    end
  end

  defp seed_baseline, do: Path.join(root(), "workspace-seed")

  defp seed_workspace do
    Application.get_env(
      :catalyst_web,
      :asset_workspace_seed,
      Application.app_dir(:catalyst_web, "priv/asset_build")
    )
  end

  defp profile(application) do
    case Application.get_env(application, :catalyst_web, []) do
      config when is_list(config) -> validate_profile(config, application)
      _invalid -> {:error, {:unavailable, application}}
    end
  end

  defp validate_profile(config, application) do
    case Keyword.fetch(config, :cd) do
      {:ok, cd} when is_binary(cd) -> {:ok, config}
      _missing_or_invalid -> {:error, {:unavailable, application}}
    end
  end

  defp input_path(config) do
    input = Enum.find_value(config[:args] || [], &input_arg/1)

    case input do
      path when is_binary(path) -> {:ok, Path.expand(path, config[:cd])}
      _missing -> {:error, {:unavailable, :tailwind_input}}
    end
  end

  defp input_arg("--input=" <> path), do: path
  defp input_arg(_arg), do: nil

  defp run_builder(builder, source, staging) do
    case builder.(source, staging) do
      :ok -> {:ok, :ok}
      {:ok, result} -> {:ok, result}
      {:error, _reason} = error -> error
      other -> {:error, {:invalid_asset_builder_result, other}}
    end
  rescue
    exception -> {:error, {:asset_build_error, Exception.message(exception)}}
  end

  defp publish_modules(source_root, staging) do
    source = Path.join(source_root, "assets/runtime")

    case File.lstat(source) do
      {:ok, %File.Stat{type: :directory}} ->
        copy_module_directory(source, Path.join(staging, "modules"), [])

      {:error, :enoent} ->
        {:ok, []}

      {:ok, _unsafe} ->
        {:error, {:invalid_runtime_module_file, []}}

      {:error, reason} ->
        {:error, {:runtime_module_stat_failed, [], reason}}
    end
  end

  defp copy_module_directory(source, destination, relative) do
    case File.ls(source) do
      {:ok, entries} -> copy_module_entries(entries, source, destination, relative)
      {:error, reason} -> {:error, {:runtime_module_read_failed, path_segments(relative), reason}}
    end
  end

  defp copy_module_entries(entries, source, destination, relative) do
    entries
    |> Enum.sort()
    |> Enum.reduce_while({:ok, []}, fn entry, {:ok, copied} ->
      case copy_module_entry(source, destination, relative, entry) do
        {:ok, paths} -> {:cont, {:ok, Enum.reverse(paths, copied)}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> then(fn
      {:ok, copied} -> {:ok, Enum.reverse(copied)}
      {:error, _reason} = error -> error
    end)
  end

  defp copy_module_entry(source, destination, relative, entry) do
    from = Path.join(source, entry)
    next_relative = [entry | relative]

    with true <- valid_module_segment?(entry),
         {:ok, stat} <- File.lstat(from) do
      copy_module_type(stat.type, from, destination, next_relative)
    else
      false ->
        {:error, {:invalid_runtime_module_path, path_segments(next_relative)}}

      {:error, reason} ->
        {:error, {:runtime_module_stat_failed, path_segments(next_relative), reason}}
    end
  end

  defp copy_module_type(:directory, source, destination, relative) do
    copy_module_directory(source, Path.join(destination, List.first(relative)), relative)
  end

  defp copy_module_type(:regular, source, destination, relative) do
    case String.ends_with?(List.first(relative), ".js") do
      true -> copy_module_file(source, destination, relative)
      false -> {:error, {:invalid_runtime_module_path, path_segments(relative)}}
    end
  end

  defp copy_module_type(_unsupported, _source, _destination, relative),
    do: {:error, {:invalid_runtime_module_file, path_segments(relative)}}

  defp copy_module_file(source, destination, relative) do
    target = Path.join(destination, List.first(relative))

    with :ok <- File.mkdir_p(destination),
         :ok <- File.cp(source, target) do
      {:ok, ["modules/" <> Enum.join(path_segments(relative), "/")]}
    else
      {:error, reason} ->
        {:error, {:runtime_module_copy_failed, path_segments(relative), reason}}
    end
  end

  defp path_segments(reversed), do: Enum.reverse(reversed)

  defp output_digest(staging, modules) do
    files = ["assets/css/app.css", "assets/js/app.js" | modules]

    with {:ok, contents} <- read_outputs(staging, files) do
      digest =
        files
        |> Enum.zip(contents)
        |> :erlang.term_to_binary()
        |> then(&:crypto.hash(:sha256, &1))
        |> Base.encode16(case: :lower)

      {:ok, digest}
    end
  end

  defp read_outputs(staging, files) do
    Enum.reduce_while(files, {:ok, []}, fn relative, {:ok, contents} ->
      path = Path.join(staging, relative)

      case File.read(path) do
        {:ok, content} -> {:cont, {:ok, [content | contents]}}
        {:error, reason} -> {:halt, {:error, {:missing_asset_output, relative, reason}}}
      end
    end)
    |> case do
      {:ok, contents} -> {:ok, Enum.reverse(contents)}
      error -> error
    end
  end

  defp install(staging, digest) do
    destination = generation_dir(digest)

    case File.dir?(destination) do
      true -> :ok
      false -> move_generation(staging, destination)
    end
  end

  defp move_generation(staging, destination) do
    with :ok <- File.mkdir_p(Path.dirname(destination)),
         :ok <- File.rename(staging, destination) do
      :ok
    else
      {:error, :eexist} -> :ok
      {:error, reason} -> {:error, {:asset_generation_install_failed, reason}}
    end
  end

  defp activate(digest) do
    with :ok <- File.mkdir_p(root()) do
      AtomicWrite.write(Path.join(root(), "current"), digest <> "\n")
    end
  end

  defp read_current, do: root() |> Path.join("current") |> File.read() |> trim_current()

  defp trim_current({:ok, value}), do: {:ok, String.trim(value)}
  defp trim_current({:error, _reason}), do: :error

  defp valid_digest?(digest), do: Regex.match?(@digest_format, digest)

  defp valid_module_segments?(segments) when is_list(segments) and segments != [] do
    Enum.all?(segments, &valid_module_segment?/1) and
      String.ends_with?(List.last(segments), ".js")
  end

  defp valid_module_segments?(_segments), do: false

  defp valid_module_segment?(segment) when is_binary(segment) do
    segment not in ["", ".", ".."] and Regex.match?(@module_segment, segment)
  end

  defp valid_module_segment?(_segment), do: false

  defp regular_descendant(root, segments) do
    with {:ok, %File.Stat{type: :directory}} <- File.lstat(root) do
      walk_descendant(root, segments)
    else
      _missing_or_unsafe -> {:error, :not_found}
    end
  end

  defp walk_descendant(parent, [file]) do
    path = Path.join(parent, file)

    case File.lstat(path) do
      {:ok, %File.Stat{type: :regular}} -> {:ok, path}
      _missing_or_unsafe -> {:error, :not_found}
    end
  end

  defp walk_descendant(parent, [directory | rest]) do
    path = Path.join(parent, directory)

    case File.lstat(path) do
      {:ok, %File.Stat{type: :directory}} -> walk_descendant(path, rest)
      _missing_or_unsafe -> {:error, :not_found}
    end
  end

  defp staging_dir do
    suffix = Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false)
    Path.join([root(), ".staging", suffix])
  end

  defp cleanup_staging do
    case File.rm_rf(Path.join(root(), ".staging")) do
      {:ok, _removed} -> :ok
      {:error, reason, path} -> {:error, {:asset_staging_cleanup_failed, path, reason}}
    end
  end
end
