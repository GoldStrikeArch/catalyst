defmodule Catalyst.Extensions.GenerationCompiler do
  @moduledoc """
  Generation-qualified compiler for managed extension service artifacts.

  The compiler gives every top-level module in one source file a physical name
  beneath an artifact-specific namespace while retaining its original logical
  identity. The extension loader uses it only when source explicitly opts in
  with `use Catalyst.Extension, api: 2, code: :generation`.

  This first prototype accepts only literal top-level `defmodule` declarations.
  Nested or dynamically generated module definitions are rejected with tagged
  errors rather than compiled with ambiguous identity.
  """

  alias Catalyst.Extension.{Manifest, ManifestFile}
  alias Catalyst.Extensions.Contribution

  alias Catalyst.Runtime.{
    ArtifactId,
    ArtifactSet,
    Artifacts,
    ImplementationRef
  }

  @doc """
  Compile one source file into an artifact-qualified physical module namespace.

  Compilation loads the physical modules into the current VM. Callers using
  this low-level function own cleanup; the extension loader runs
  `compile_managed_file/1` in bounded work and then registers the returned set.
  """
  @spec compile_file(Path.t()) :: {:ok, ArtifactSet.t()} | {:error, term()}
  def compile_file(path) when is_binary(path), do: do_compile_file(path, false)

  @doc false
  @spec compile_preflight_file(Path.t()) :: {:ok, ArtifactSet.t()} | {:error, term()}
  def compile_preflight_file(path) when is_binary(path), do: do_compile_file(path, true)

  defp do_compile_file(path, preflight_only?) do
    with {:ok, source} <- File.read(path),
         {:ok, quoted} <- parse(source, path),
         :ok <- validate_source_forms(quoted),
         {:ok, logical_modules} <- top_level_modules(quoted),
         {:ok, external} <- external_manifest(path, logical_modules),
         :ok <- validate_external_source_mode(external, quoted),
         :ok <- validate_local_trust(external, preflight_only?),
         artifact_id = ArtifactId.from_source(artifact_source(source, external)),
         :ok <- Artifacts.reserve_namespace(artifact_id),
         mappings = module_mappings(logical_modules, artifact_id),
         {:ok, rewritten} <- rewrite(quoted, mappings) do
      case cached_artifact(artifact_id) do
        {:ok, artifact} ->
          {:ok, artifact}

        :error ->
          compile_artifact(rewritten, path, artifact_id, mappings, external_manifests(external))
      end
    end
  end

  @doc """
  Compile an explicitly opted-in API-v2 source artifact into a contribution.

  The returned contribution leaves `modules` and `beams` empty because physical
  module ownership belongs to `Catalyst.Runtime.Artifacts`, not the legacy
  source-module version stack. The caller must register the returned artifact
  after its bounded compile task succeeds.
  """
  @spec compile_managed_file(Path.t()) ::
          {:ok, Contribution.t()} | {:error, term(), [module()]}
  def compile_managed_file(path) when is_binary(path) do
    case compile_file(path) do
      {:ok, artifact} ->
        case managed_contribution(artifact) do
          {:ok, contribution} -> {:ok, contribution}
          {:error, reason} -> {:error, reason, ArtifactSet.physical_modules(artifact)}
        end

      {:error, reason} ->
        {:error, reason, []}
    end
  end

  @doc "True when source explicitly requests generation-qualified code loading."
  @spec generation_managed_file?(Path.t()) :: boolean()
  def generation_managed_file?(path) when is_binary(path) do
    case ManifestFile.exists?(path) do
      true ->
        true

      false ->
        with {:ok, source} <- File.read(path),
             {:ok, quoted} <- parse(source, path) do
          Enum.any?(top_level_forms(quoted), &generation_module?/1)
        else
          _error -> false
        end
    end
  end

  @doc """
  Replace artifact-local physical service modules with implementation references.

  Other declaration fields are unchanged. This keeps the prototype constrained
  to service dispatch while process, health-check, and migration artifact
  semantics remain explicit future work.
  """
  @spec bind_manifest(Manifest.t(), ArtifactSet.t()) :: Manifest.t()
  def bind_manifest(%Manifest{} = manifest, %ArtifactSet{} = artifact) do
    services = Enum.map(manifest.services, &bind_service(&1, artifact))
    %{manifest | services: services}
  end

  @doc "Read and bind every API-v2 manifest carried by an artifact."
  @spec manifests(ArtifactSet.t()) :: [Manifest.t()]
  def manifests(%ArtifactSet{} = artifact) do
    artifact
    |> artifact_manifests()
    |> Enum.map(&bind_manifest(&1, artifact))
  end

  defp managed_contribution(artifact) do
    modules = ArtifactSet.physical_modules(artifact)
    extension_modules = Enum.filter(modules, &Catalyst.Extension.manifest_module?/1)
    imperative_modules = Enum.filter(modules, &Catalyst.Extension.imperative_module?/1)
    tool_modules = Enum.filter(modules, &tool_module?/1)
    manifests = manifests(artifact)

    with :ok <- require_manifest_source(artifact, extension_modules),
         :ok <- validate_embedded_trust(artifact, manifests),
         :ok <- reject_imperative_modules(imperative_modules),
         :ok <- reject_tool_modules(tool_modules),
         :ok <- validate_supported_manifests(manifests),
         :ok <- require_artifact_reference(manifests, artifact.id) do
      {:ok,
       %Contribution{
         modules: [],
         beams: %{},
         ext_mods: extension_modules,
         manifests: manifests,
         artifact: artifact,
         tool_mods: [],
         tool_names: [],
         metadata: manifest_metadata(manifests, extension_modules)
       }}
    else
      {:error, reason} ->
        purge_modules(ArtifactSet.physical_modules(artifact))
        {:error, reason}
    end
  end

  defp require_manifest_modules([]), do: {:error, :generation_artifact_requires_api_v2_manifest}

  defp require_manifest_modules(modules) do
    case Enum.all?(modules, &(Catalyst.Extension.code_mode(&1) == :generation)) do
      true -> :ok
      false -> {:error, :mixed_extension_code_modes}
    end
  end

  defp require_manifest_source(%ArtifactSet{manifests: []}, modules),
    do: require_manifest_modules(modules)

  defp require_manifest_source(%ArtifactSet{manifests: [_ | _]}, []), do: :ok

  defp require_manifest_source(%ArtifactSet{manifests: [_ | _]}, modules),
    do: {:error, {:external_manifest_embedded_extensions_not_supported, modules}}

  defp validate_embedded_trust(%ArtifactSet{manifests: [_ | _]}, _manifests), do: :ok

  defp validate_embedded_trust(%ArtifactSet{manifests: []}, manifests) do
    case Enum.find(manifests, &(not Catalyst.Extension.Trust.unrestricted?(&1.trust))) do
      nil ->
        :ok

      manifest ->
        {:error, {:isolated_trust_requires_external_manifest, manifest.id, manifest.trust}}
    end
  end

  defp reject_imperative_modules([]), do: :ok

  defp reject_imperative_modules(modules),
    do: {:error, {:generation_artifact_imperative_modules_not_supported, modules}}

  defp reject_tool_modules([]), do: :ok

  defp reject_tool_modules(modules),
    do: {:error, {:generation_artifact_tool_modules_not_supported, modules}}

  defp validate_supported_manifests(manifests) do
    unsupported =
      Enum.flat_map(manifests, fn manifest ->
        [:extension_points, :contributions, :processes, :health_checks, :migrations]
        |> Enum.filter(&(Map.fetch!(manifest, &1) != []))
        |> Enum.map(&{manifest.id, &1})
      end)

    case unsupported do
      [] -> :ok
      declarations -> {:error, {:generation_artifact_declarations_not_supported, declarations}}
    end
  end

  defp require_artifact_reference(manifests, artifact_id) do
    case artifact_id in Artifacts.referenced_ids(manifests) do
      true -> :ok
      false -> {:error, :generation_artifact_requires_local_service}
    end
  end

  defp parse(source, path) do
    case Code.string_to_quoted(source, file: path, columns: true) do
      {:ok, quoted} -> {:ok, quoted}
      {:error, reason} -> {:error, {:parse, reason}}
    end
  end

  defp top_level_modules(quoted) do
    top_level = quoted |> top_level_forms() |> Enum.flat_map(&module_name/1)
    all = module_names(quoted)

    cond do
      top_level == [] ->
        {:error, :no_top_level_modules}

      :dynamic in top_level or :dynamic in all ->
        {:error, :nested_or_dynamic_modules_not_supported}

      top_level != all ->
        {:error, :nested_or_dynamic_modules_not_supported}

      length(top_level) != MapSet.size(MapSet.new(top_level)) ->
        {:error, :duplicate_modules}

      true ->
        {:ok, top_level}
    end
  end

  defp top_level_forms({:__block__, _metadata, forms}), do: forms
  defp top_level_forms(form), do: [form]

  defp module_names(quoted) do
    {_quoted, {modules, _quote_depth}} =
      Macro.traverse(
        quoted,
        {[], 0},
        &collect_module_name/2,
        &leave_module_form/2
      )

    Enum.reverse(modules)
  end

  defp collect_module_name({:quote, _metadata, _args} = node, {modules, depth}),
    do: {node, {modules, depth + 1}}

  defp collect_module_name(
         {:defmodule, _metadata, [name | _body]} = node,
         {modules, 0}
       ) do
    case alias_module(name) do
      {:ok, module} -> {node, {[module | modules], 0}}
      :error -> {node, {[:dynamic | modules], 0}}
    end
  end

  defp collect_module_name(node, state), do: {node, state}

  defp leave_module_form({:quote, _metadata, _args} = node, {modules, depth}),
    do: {node, {modules, depth - 1}}

  defp leave_module_form(node, state), do: {node, state}

  defp module_name({:defmodule, _metadata, [name | _body]}) do
    case alias_module(name) do
      {:ok, module} -> [module]
      :error -> [:dynamic]
    end
  end

  defp module_name(_form), do: []

  defp alias_module({:__aliases__, _metadata, parts}) when is_list(parts),
    do: {:ok, parts |> drop_elixir_prefix() |> Module.concat()}

  defp alias_module(module) when is_atom(module), do: {:ok, module}
  defp alias_module(_name), do: :error

  defp module_mappings(logical_modules, artifact_id) do
    Map.new(logical_modules, fn logical ->
      physical =
        Module.concat([
          Catalyst,
          RuntimeArtifact,
          ArtifactId.module_segment(artifact_id) | Module.split(logical)
        ])

      {logical, physical}
    end)
  end

  defp rewrite(quoted, mappings) do
    case curly_alias?(quoted) do
      true ->
        {:error, :generation_artifact_curly_aliases_not_supported}

      false ->
        {:ok, rewrite_modules(quoted, mappings)}
    end
  end

  defp rewrite_modules(quoted, mappings) do
    Macro.prewalk(quoted, fn
      {:defmodule, metadata, [name, body]} = node ->
        case module_target(name, mappings) do
          {:ok, physical} ->
            {:defmodule, metadata, [physical, body]}

          :error ->
            node
        end

      {:__aliases__, metadata, _parts} = alias_ast ->
        case module_target(alias_ast, mappings) do
          {:ok, physical} -> module_alias(physical, metadata)
          :error -> alias_ast
        end

      module when is_atom(module) ->
        Map.get(mappings, module, module)

      node ->
        node
    end)
  end

  defp module_alias(module, metadata) do
    short =
      module
      |> Module.split()
      |> List.last()
      |> String.to_existing_atom()

    {:__aliases__, Keyword.put(metadata, :alias, module), [short]}
  end

  defp module_target(name, mappings) do
    with {:ok, logical} <- alias_module(name),
         {:ok, physical} <- Map.fetch(mappings, logical) do
      {:ok, physical}
    end
  end

  defp compile(quoted, path) do
    {:ok, Code.compile_quoted(quoted, path)}
  rescue
    error -> {:error, {:compile, Exception.message(error)}}
  catch
    kind, reason -> {:error, {:compile, {kind, reason}}}
  end

  defp compile_artifact(rewritten, path, artifact_id, mappings, manifests) do
    case compile(rewritten, path) do
      {:ok, compiled} ->
        with :ok <- validate_compiled_modules(compiled, mappings) do
          {:ok, ArtifactSet.new(artifact_id, mappings, Map.new(compiled), manifests)}
        else
          {:error, _reason} = error ->
            purge_modules(Enum.map(compiled, &elem(&1, 0)))
            error
        end

      {:error, _reason} = error ->
        purge_modules(Map.values(mappings))
        error
    end
  end

  defp validate_compiled_modules(compiled, mappings) do
    emitted = compiled |> Enum.map(&elem(&1, 0)) |> MapSet.new()
    expected = mappings |> Map.values() |> MapSet.new()

    case MapSet.equal?(emitted, expected) do
      true ->
        :ok

      false ->
        escaped =
          emitted
          |> MapSet.difference(expected)
          |> MapSet.to_list()
          |> Enum.sort()

        missing =
          expected
          |> MapSet.difference(emitted)
          |> MapSet.to_list()
          |> Enum.sort()

        {:error, {:artifact_module_mismatch, escaped, missing}}
    end
  end

  defp cached_artifact(artifact_id) do
    case Artifacts.fetch_set(artifact_id) do
      {:ok, artifact} ->
        case Enum.all?(ArtifactSet.physical_modules(artifact), &Code.ensure_loaded?/1) do
          true -> {:ok, artifact}
          false -> :error
        end

      :error ->
        :error
    end
  end

  defp external_manifest(path, logical_modules) do
    case ManifestFile.load(path, logical_modules) do
      :none -> {:ok, nil}
      {:ok, loaded} -> {:ok, loaded}
      {:error, _reason} = error -> error
    end
  end

  defp validate_external_source_mode(nil, _quoted), do: :ok

  defp validate_external_source_mode(%{manifest: %Manifest{}}, quoted) do
    case Enum.any?(top_level_forms(quoted), &generation_module?/1) do
      true -> {:error, :external_manifest_cannot_mix_with_embedded_generation_manifest}
      false -> :ok
    end
  end

  defp validate_local_trust(_external, true), do: :ok
  defp validate_local_trust(nil, false), do: :ok

  defp validate_local_trust(%{manifest: %Manifest{} = manifest}, false) do
    case Catalyst.Extension.Trust.unrestricted?(manifest.trust) do
      true -> :ok
      false -> {:error, {:isolated_runtime_transport_required, manifest.id, manifest.trust}}
    end
  end

  defp artifact_source(source, nil), do: source

  defp artifact_source(source, %{bytes: manifest}) do
    IO.iodata_to_binary([source, <<0>>, "catalyst.external-manifest", <<0>>, manifest])
  end

  defp external_manifests(nil), do: []
  defp external_manifests(%{manifest: %Manifest{} = manifest}), do: [manifest]

  defp artifact_manifests(%ArtifactSet{manifests: [_ | _] = manifests}), do: manifests

  defp artifact_manifests(%ArtifactSet{} = artifact) do
    artifact
    |> ArtifactSet.physical_modules()
    |> Catalyst.Extension.manifests_of()
  end

  defp manifest_metadata(manifests, extension_modules) do
    case manifests do
      [] -> Catalyst.Extension.metadata_of(extension_modules)
      manifests -> Enum.reduce(manifests, %{}, &Map.merge(&2, &1.metadata))
    end
  end

  defp validate_source_forms(quoted) do
    {_quoted, {unsupported, _quote_depth}} =
      Macro.traverse(
        quoted,
        {[], 0},
        &collect_source_form/2,
        &leave_source_form/2
      )

    case unsupported do
      [] ->
        :ok

      forms ->
        {:error, {:generation_artifact_module_emitters_not_supported, Enum.reverse(forms)}}
    end
  end

  defp collect_source_form({:quote, _metadata, _args} = node, {forms, depth}),
    do: {node, {forms, depth + 1}}

  defp collect_source_form(
         {kind, metadata, _args} = node,
         {forms, 0}
       )
       when kind in [:defprotocol, :defimpl, :defrecord, :defrecordp],
       do: {node, {[{kind, Keyword.get(metadata, :line)} | forms], 0}}

  defp collect_source_form(node, state), do: {node, state}

  defp leave_source_form({:quote, _metadata, _args} = node, {forms, depth}),
    do: {node, {forms, depth - 1}}

  defp leave_source_form(node, state), do: {node, state}

  defp curly_alias?(quoted) do
    {_quoted, found?} =
      Macro.prewalk(quoted, false, fn
        {{:., _, [{:__aliases__, _, _}, :{}]}, _, _} = node, _found? -> {node, true}
        node, found? -> {node, found?}
      end)

    found?
  end

  defp generation_module?({:defmodule, _metadata, [_name, [do: body]]}) do
    body
    |> top_level_forms()
    |> generation_body?(%{})
  end

  defp generation_module?(_form), do: false

  defp generation_body?([], _aliases), do: false

  defp generation_body?([form | forms], aliases) do
    case alias_declaration(form) do
      {:ok, short, target} ->
        generation_body?(forms, Map.put(aliases, short, target))

      :error ->
        generation_use?(form, aliases) or generation_body?(forms, aliases)
    end
  end

  defp alias_declaration({:alias, _metadata, [target | opts]}) do
    with {:ok, module} <- alias_module(target),
         {:ok, short} <- alias_short_name(module, opts) do
      {:ok, short, module}
    end
  end

  defp alias_declaration(_form), do: :error

  defp alias_short_name(module, []) do
    module
    |> Module.split()
    |> List.last()
    |> then(&{:ok, Module.concat([&1])})
  end

  defp alias_short_name(_module, [[as: alias_ast]]), do: alias_module(alias_ast)
  defp alias_short_name(_module, _opts), do: :error

  defp generation_use?({:use, _metadata, [extension, opts]}, aliases) do
    with true <- literal_generation_opts?(opts),
         {:ok, module} <- alias_module(extension) do
      module == Catalyst.Extension or Map.get(aliases, module) == Catalyst.Extension
    else
      _not_generation_use -> false
    end
  end

  defp generation_use?(_form, _aliases), do: false

  defp literal_generation_opts?(opts) when is_list(opts),
    do: Keyword.get(opts, :api) == 2 and Keyword.get(opts, :code) == :generation

  defp literal_generation_opts?(_opts), do: false

  defp drop_elixir_prefix([:"Elixir" | parts]), do: parts
  defp drop_elixir_prefix(parts), do: parts

  defp tool_module?(module) do
    function_exported?(module, :name, 0) and
      function_exported?(module, :parameters, 0) and
      function_exported?(module, :execute, 2)
  end

  defp purge_modules(modules) do
    Enum.each(modules, fn module ->
      :code.purge(module)
      :code.delete(module)
      :code.purge(module)
    end)
  end

  defp bind_service(service, artifact) do
    with {:ok, implementation} <- fetch_implementation(service),
         {:ok, logical, physical} <- artifact_implementation(artifact, implementation) do
      put_implementation(
        service,
        ImplementationRef.local(logical, physical, artifact.id)
      )
    else
      :error -> service
    end
  end

  defp artifact_implementation(artifact, implementation) do
    case ArtifactSet.logical(artifact, implementation) do
      {:ok, logical} ->
        {:ok, logical, implementation}

      :error ->
        case ArtifactSet.target(artifact, implementation) do
          {:ok, physical} -> {:ok, implementation, physical}
          :error -> :error
        end
    end
  end

  defp fetch_implementation(service) when is_map(service) do
    case Map.fetch(service, :implementation) do
      {:ok, implementation} -> {:ok, implementation}
      :error -> Map.fetch(service, "implementation")
    end
  end

  defp fetch_implementation(service) when is_list(service) do
    case Keyword.fetch(service, :implementation) do
      {:ok, implementation} -> {:ok, implementation}
      :error -> :error
    end
  end

  defp fetch_implementation(_service), do: :error

  defp put_implementation(service, implementation) when is_map(service) do
    case Map.has_key?(service, :implementation) do
      true -> Map.put(service, :implementation, implementation)
      false -> Map.put(service, "implementation", implementation)
    end
  end

  defp put_implementation(service, implementation) when is_list(service),
    do: Keyword.put(service, :implementation, implementation)
end
