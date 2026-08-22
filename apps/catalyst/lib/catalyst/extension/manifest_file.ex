defmodule Catalyst.Extension.ManifestFile do
  @moduledoc """
  Data-only manifest reader for generation-managed extension source files.

  An external manifest lives beside its source as `<source>.manifest.json`.
  Catalyst parses and validates it before compiling the source, so manifest
  discovery cannot execute extension code. The current external format is
  deliberately limited to service claims, matching the generation compiler's
  supported activation surface.
  """

  alias Catalyst.Extension.Manifest
  alias Catalyst.Runtime.Context

  @default_max_bytes 262_144
  @top_fields ~w(api id version requires services extension_points contributions processes health_checks migrations capabilities trust metadata)
  @service_fields ~w(key contract implementation scope priority binding metadata)
  @metadata_fields %{"name" => :name, "description" => :description, "version" => :version}
  @trust %{
    "compiled_trusted" => :compiled_trusted,
    "local_trusted" => :local_trusted,
    "isolated_worker" => :isolated_worker,
    "remote_service" => :remote_service
  }
  @capabilities %{
    "computer" => :computer,
    "credentials" => :credentials,
    "desktop" => :desktop,
    "filesystem" => :filesystem,
    "network" => :network,
    "notifications" => :notifications,
    "process" => :process,
    "workspace" => :workspace
  }
  @bindings %{
    "live" => :live,
    "action" => {:pin, :action},
    "document" => {:pin, :document},
    "generation" => {:pin, :generation},
    "mount" => {:pin, :mount},
    "request" => {:pin, :request},
    "run" => {:pin, :run},
    "session" => {:pin, :session},
    "tool_batch" => {:pin, :tool_batch},
    "turn" => {:pin, :turn}
  }
  @dimensions Map.new(Context.dimensions(), &{Atom.to_string(&1), &1})

  @typedoc "A validated external manifest plus its exact source bytes."
  @type loaded :: %{manifest: Manifest.t(), bytes: binary()}

  @doc "Return the adjacent data-manifest path for an extension source."
  @spec path(Path.t()) :: Path.t()
  def path(source_path) when is_binary(source_path), do: source_path <> ".manifest.json"

  @doc "Whether an adjacent data manifest exists."
  @spec exists?(Path.t()) :: boolean()
  def exists?(source_path) when is_binary(source_path), do: File.regular?(path(source_path))

  @doc "Read and validate the adjacent manifest without evaluating extension code."
  @spec load(Path.t(), [module()]) :: :none | {:ok, loaded()} | {:error, term()}
  def load(source_path, logical_modules)
      when is_binary(source_path) and is_list(logical_modules) do
    manifest_path = path(source_path)
    max_bytes = max_bytes()

    case File.stat(manifest_path) do
      {:ok, %{type: :regular, size: size}} when size <= max_bytes ->
        with {:ok, bytes} <- File.read(manifest_path),
             {:ok, decoded} <- Jason.decode(bytes),
             {:ok, manifest} <- normalize(decoded, logical_modules) do
          {:ok, %{manifest: manifest, bytes: bytes}}
        else
          {:error, %Jason.DecodeError{} = error} ->
            {:error, {:invalid_external_manifest_json, Exception.message(error)}}

          {:error, reason} ->
            {:error, reason}
        end

      {:ok, %{type: :regular, size: size}} ->
        {:error, {:external_manifest_too_large, size, max_bytes}}

      {:ok, _other} ->
        {:error, :external_manifest_not_regular}

      {:error, :enoent} ->
        :none

      {:error, reason} ->
        {:error, {:external_manifest_read_failed, reason}}
    end
  end

  defp normalize(decoded, logical_modules) when is_map(decoded) do
    with :ok <- known_keys(decoded, @top_fields, :manifest),
         :ok <- empty_unsupported_declarations(decoded),
         {:ok, trust} <- known_value(@trust, Map.get(decoded, "trust", "local_trusted"), :trust),
         {:ok, capabilities} <- normalize_capabilities(Map.get(decoded, "capabilities", [])),
         {:ok, requires} <- normalize_requires(Map.get(decoded, "requires", [])),
         {:ok, services} <- normalize_services(Map.get(decoded, "services", []), logical_modules),
         {:ok, metadata} <- normalize_metadata(Map.get(decoded, "metadata", %{})) do
      Manifest.new(%{
        api: Map.get(decoded, "api", 2),
        id: Map.get(decoded, "id"),
        version: Map.get(decoded, "version"),
        requires: requires,
        services: services,
        capabilities: capabilities,
        trust: trust,
        metadata: metadata
      })
    end
  end

  defp normalize(decoded, _logical_modules),
    do: {:error, {:invalid_external_manifest, decoded}}

  defp empty_unsupported_declarations(decoded) do
    fields = ~w(extension_points contributions processes health_checks migrations)

    case Enum.find(fields, &(Map.get(decoded, &1, []) != [])) do
      nil -> :ok
      field -> {:error, {:external_manifest_declaration_not_supported, field}}
    end
  end

  defp normalize_services(services, logical_modules) when is_list(services) do
    module_index =
      Map.new(logical_modules, fn module ->
        {module |> Module.split() |> Enum.join("."), module}
      end)

    services
    |> Enum.reduce_while({:ok, []}, fn service, {:ok, acc} ->
      case normalize_service(service, module_index) do
        {:ok, normalized} -> {:cont, {:ok, [normalized | acc]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> reverse_result()
  end

  defp normalize_services(services, _logical_modules),
    do: {:error, {:invalid_external_manifest_services, services}}

  defp normalize_service(service, module_index) when is_map(service) do
    with :ok <- known_keys(service, @service_fields, :service),
         {:ok, key} <- normalize_key(Map.get(service, "key")),
         {:ok, contract} <- normalize_contract(Map.get(service, "contract")),
         {:ok, implementation} <-
           normalize_implementation(Map.get(service, "implementation"), module_index),
         {:ok, scope} <- normalize_scope(Map.get(service, "scope", %{})),
         {:ok, binding} <- optional_known_value(@bindings, Map.get(service, "binding"), :binding),
         {:ok, metadata} <- normalize_metadata(Map.get(service, "metadata", %{})) do
      {:ok,
       %{
         key: key,
         contract: contract,
         implementation: implementation,
         scope: scope,
         metadata: metadata
       }
       |> maybe_put(:priority, Map.get(service, "priority"))
       |> maybe_put(:binding, binding)}
    end
  end

  defp normalize_service(service, _module_index),
    do: {:error, {:invalid_external_manifest_service, service}}

  defp normalize_key(key) when is_binary(key), do: {:ok, key}

  defp normalize_key([namespace, name]) when is_binary(namespace) and is_binary(name),
    do: {:ok, {namespace, name}}

  defp normalize_key([namespace, name, slot])
       when is_binary(namespace) and is_binary(name) and is_binary(slot),
       do: {:ok, {namespace, name, slot}}

  defp normalize_key(key), do: {:error, {:invalid_external_manifest_service_key, key}}

  defp normalize_contract([id, version]) when is_binary(id) and is_integer(version),
    do: {:ok, {id, version}}

  defp normalize_contract(%{"id" => id, "version" => version})
       when is_binary(id) and is_integer(version),
       do: {:ok, {id, version}}

  defp normalize_contract(contract),
    do: {:error, {:invalid_external_manifest_contract, contract}}

  defp normalize_implementation(name, module_index) when is_binary(name) do
    case Map.fetch(module_index, name) do
      {:ok, module} -> {:ok, module}
      :error -> {:error, {:unknown_external_manifest_module, name}}
    end
  end

  defp normalize_implementation(name, _module_index),
    do: {:error, {:invalid_external_manifest_module, name}}

  defp normalize_scope(scope) when is_map(scope) do
    scope
    |> Enum.reduce_while({:ok, %{}}, fn {dimension, value}, {:ok, acc} ->
      with {:ok, key} <- known_value(@dimensions, dimension, :scope_dimension),
           true <- is_binary(value) and value != "" do
        {:cont, {:ok, Map.put(acc, key, value)}}
      else
        false -> {:halt, {:error, {:invalid_external_manifest_scope, dimension, value}}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp normalize_scope(scope), do: {:error, {:invalid_external_manifest_scope, scope}}

  defp normalize_capabilities(capabilities) when is_list(capabilities) do
    capabilities
    |> Enum.reduce_while({:ok, []}, fn capability, {:ok, acc} ->
      case known_value(@capabilities, capability, :capability) do
        {:ok, value} -> {:cont, {:ok, [value | acc]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> reverse_result()
  end

  defp normalize_capabilities(capabilities),
    do: {:error, {:invalid_external_manifest_capabilities, capabilities}}

  defp normalize_requires(requires) when is_list(requires) do
    requires
    |> Enum.reduce_while({:ok, []}, fn
      %{"id" => id, "requirement" => requirement}, {:ok, acc}
      when is_binary(id) and is_binary(requirement) ->
        {:cont, {:ok, [%{id: id, requirement: requirement} | acc]}}

      dependency, _acc ->
        {:halt, {:error, {:invalid_external_manifest_dependency, dependency}}}
    end)
    |> reverse_result()
  end

  defp normalize_requires(requires),
    do: {:error, {:invalid_external_manifest_requires, requires}}

  defp normalize_metadata(metadata) when is_map(metadata) do
    case Enum.find(Map.keys(metadata), &(not is_binary(&1))) do
      nil ->
        {:ok,
         Map.new(metadata, fn {key, value} -> {Map.get(@metadata_fields, key, key), value} end)}

      invalid ->
        {:error, {:invalid_external_manifest_metadata_key, invalid}}
    end
  end

  defp normalize_metadata(metadata),
    do: {:error, {:invalid_external_manifest_metadata, metadata}}

  defp known_keys(map, allowed, kind) do
    case Map.keys(map) -- allowed do
      [] -> :ok
      unknown -> {:error, {:unknown_external_manifest_fields, kind, Enum.sort(unknown)}}
    end
  end

  defp known_value(values, key, field) do
    case Map.fetch(values, key) do
      {:ok, value} -> {:ok, value}
      :error -> {:error, {:unknown_external_manifest_value, field, key}}
    end
  end

  defp optional_known_value(_values, nil, _field), do: {:ok, nil}
  defp optional_known_value(values, key, field), do: known_value(values, key, field)

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp reverse_result({:ok, values}), do: {:ok, Enum.reverse(values)}
  defp reverse_result({:error, _reason} = error), do: error

  defp max_bytes do
    case Application.get_env(:catalyst, :external_manifest_max_bytes, @default_max_bytes) do
      value when is_integer(value) and value > 0 -> value
      _invalid -> @default_max_bytes
    end
  end
end
