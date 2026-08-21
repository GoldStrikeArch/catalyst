defmodule Catalyst.Extension do
  @moduledoc """
  Entry point for imperative API-v1 and declarative API-v2 extensions.

  API v1 is Catalyst's existing owner-scoped `setup/1` model. When its source
  file is loaded (`Catalyst.Extensions.load_file/1`), Catalyst calls `setup/1`
  with a `Catalyst.ExtensionAPI`:

      defmodule MyExt do
        use Catalyst.Extension

        @impl true
        def setup(api) do
          Catalyst.ExtensionAPI.register_tool(api, MyTool)
          Catalyst.ExtensionAPI.register_hook(api, :before_tool_call, &MyExt.gate/1)
          :ok
        end

        def gate(%{name: "bash"}), do: {:block, "bash disabled"}
        def gate(_), do: :cont
      end

  API v2 persists an inert manifest in the compiled module:

      defmodule MyDeclarativeExt do
        use Catalyst.Extension, api: 2

        manifest %{
          id: "my-declarative-extension",
          version: "1.0.0",
          contributions: []
        }
      end

  Discovering API-v2 metadata does not invoke extension-authored callbacks.
  Catalyst combines enabled v2 manifests into one candidate, starts its declared
  process subtree, runs bounded health checks, and atomically publishes the
  complete managed graph only after staging succeeds.

  Everything registered is tagged with the extension's `owner` id (the source
  file's basename), so reloading the file revokes the previous contributions
  before re-running `setup/1` — reloads are idempotent.

  Tool-only files that just `use Catalyst.Tools.Tool` (no `setup/1`) keep working
  unchanged; their tool modules are auto-registered.
  """

  require Logger

  alias Catalyst.Tasks
  alias Catalyst.Extension.Manifest

  @metadata_timeout 1_000

  @doc """
  Register this extension's contributions through the owner-scoped API.

  Return `:ok` after successful setup or `{:error, reason}` to reject the load.
  """
  @callback setup(api :: Catalyst.ExtensionAPI.t()) :: :ok | {:error, term()}

  @doc """
  Optional self-description (e.g. `%{name: "…", description: "…", version: "…"}`),
  surfaced by `Catalyst.Extensions.list_loaded/0` and the `/extensions` panel.
  """
  @callback metadata() :: %{optional(atom()) => term()}

  @optional_callbacks metadata: 0

  defmacro __using__(opts) do
    case Keyword.get(opts, :api, 1) do
      1 ->
        quote do
          @behaviour Catalyst.Extension
          Module.register_attribute(__MODULE__, :catalyst_extension_api, persist: true)
          @catalyst_extension_api 1
        end

      2 ->
        quote do
          Module.register_attribute(__MODULE__, :catalyst_extension_api, persist: true)
          Module.register_attribute(__MODULE__, :catalyst_extension_manifest, persist: true)
          @catalyst_extension_api 2
          @before_compile Catalyst.Extension
          import Catalyst.Extension, only: [manifest: 1]
        end

      api ->
        raise ArgumentError, "unsupported Catalyst extension API: #{inspect(api)}"
    end
  end

  @doc """
  Persist an API-v2 manifest in the compiling extension module.

  The expression must evaluate during compilation to inert manifest data.
  Defining more than one manifest is rejected.
  """
  defmacro manifest(spec) do
    quote bind_quoted: [spec: spec] do
      case Module.get_attribute(__MODULE__, :catalyst_extension_manifest) do
        nil ->
          @catalyst_extension_manifest Catalyst.Extension.Manifest.new!(spec)

        _manifest ->
          raise ArgumentError, "an API-v2 extension may define only one manifest"
      end
    end
  end

  @doc false
  defmacro __before_compile__(env) do
    case Module.get_attribute(env.module, :catalyst_extension_manifest) do
      %Manifest{} ->
        quote do
        end

      _missing ->
        raise CompileError,
          file: env.file,
          line: env.line,
          description: "API-v2 Catalyst extension must declare manifest/1"
    end
  end

  @doc "Return the declared extension API version, or `:unknown` for other modules."
  @spec api_version(module()) :: 1 | 2 | :unknown
  def api_version(module) do
    case persisted_attribute(module, :catalyst_extension_api) do
      api when api in [1, 2] -> api
      _other -> :unknown
    end
  end

  @doc "True when a loaded module uses the imperative API-v1 `setup/1` lifecycle."
  @spec imperative_module?(module()) :: boolean()
  def imperative_module?(module) do
    Code.ensure_loaded?(module) and api_version(module) in [1, :unknown] and
      function_exported?(module, :setup, 1)
  end

  @doc "True when a loaded module carries a validated API-v2 manifest."
  @spec manifest_module?(module()) :: boolean()
  def manifest_module?(module) do
    Code.ensure_loaded?(module) and api_version(module) == 2 and
      match?({:ok, _}, manifest_of(module))
  end

  @doc "True if `module` is a loaded API-v1 or API-v2 extension."
  @spec extension_module?(module()) :: boolean()
  def extension_module?(module), do: imperative_module?(module) or manifest_module?(module)

  @doc "Read a validated API-v2 manifest from persisted BEAM metadata."
  @spec manifest_of(module()) :: {:ok, Manifest.t()} | :error
  def manifest_of(module) do
    case persisted_attribute(module, :catalyst_extension_manifest) do
      %Manifest{} = manifest -> {:ok, manifest}
      _other -> :error
    end
  end

  @doc "Read API-v2 manifests from loaded modules in declaration order."
  @spec manifests_of([module()]) :: [Manifest.t()]
  def manifests_of(modules) do
    Enum.flat_map(modules, fn module ->
      case manifest_of(module) do
        {:ok, manifest} -> [manifest]
        :error -> []
      end
    end)
  end

  @doc """
  Merge extension metadata without invoking API-v2 extension callbacks.

  API-v2 metadata comes from persisted manifests. API-v1 retains the existing
  crash-safe, bounded `metadata/0` callback.
  """
  @spec metadata_of([module()]) :: map()
  def metadata_of(modules) do
    modules
    |> Enum.reduce(%{}, fn module, metadata ->
      Map.merge(metadata, module_metadata(module))
    end)
  end

  defp module_metadata(module) do
    case manifest_of(module) do
      {:ok, manifest} -> manifest.metadata
      :error -> legacy_metadata(module)
    end
  end

  defp legacy_metadata(module) do
    case Code.ensure_loaded?(module) and function_exported?(module, :metadata, 0) do
      true -> safe_metadata(module)
      false -> %{}
    end
  end

  defp safe_metadata(mod) do
    task = Tasks.async(fn -> mod.metadata() end)

    case Tasks.await(task, metadata_timeout()) do
      {:ok, %{} = metadata} ->
        metadata

      {:ok, other} ->
        Logger.warning("[extensions] #{inspect(mod)}.metadata/0 returned #{inspect(other)}")
        %{}

      {:exit, reason} ->
        Logger.warning("[extensions] #{inspect(mod)}.metadata/0 exited: #{inspect(reason)}")
        %{}

      :timeout ->
        Logger.warning("[extensions] #{inspect(mod)}.metadata/0 timed out")
        %{}
    end
  rescue
    _ -> %{}
  catch
    _kind, _reason -> %{}
  end

  defp metadata_timeout do
    Application.get_env(:catalyst, :extension_metadata_timeout, @metadata_timeout)
  end

  defp persisted_attribute(module, name) do
    with true <- Code.ensure_loaded?(module),
         attributes when is_list(attributes) <- module.__info__(:attributes),
         values when is_list(values) <- Keyword.get(attributes, name, []),
         value when not is_nil(value) <- List.last(values) do
      value
    else
      _other -> nil
    end
  end
end
