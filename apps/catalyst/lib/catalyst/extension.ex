defmodule Catalyst.Extension do
  @moduledoc """
  Behaviour for a Catalyst extension — the unified, multi-kind plug-in entry
  point (Catalyst's analog of PI's `ExtensionFactory = (pi) => void`).

  An extension is a module with a `setup/1` callback. When its source file is
  loaded (`Catalyst.Extensions.load_file/1`), Catalyst calls `setup/1` with a
  `Catalyst.ExtensionAPI` struct through which the extension defines generic
  extension points and registers any mix of tools, loop hooks, event observers,
  LLM providers, and UI renderers/components/pages/commands:

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

  Everything registered is tagged with the extension's `owner` id (the source
  file's basename), so reloading the file revokes the previous contributions
  before re-running `setup/1` — reloads are idempotent.

  Tool-only files that just `use Catalyst.Tools.Tool` (no `setup/1`) keep working
  unchanged; their tool modules are auto-registered.
  """

  require Logger

  alias Catalyst.Tasks

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

  defmacro __using__(_opts) do
    quote do
      @behaviour Catalyst.Extension
    end
  end

  @doc "True if `module` is a loaded extension (exports `setup/1`)."
  @spec extension_module?(module()) :: boolean()
  def extension_module?(module) do
    Code.ensure_loaded?(module) and function_exported?(module, :setup, 1)
  end

  @doc "Merged `metadata/0` of the given modules (crash-safe; non-map results ignored)."
  @spec metadata_of([module()]) :: %{optional(atom()) => term()}
  def metadata_of(modules) do
    modules
    |> Enum.filter(&(Code.ensure_loaded?(&1) and function_exported?(&1, :metadata, 0)))
    |> Enum.reduce(%{}, fn mod, acc -> Map.merge(acc, safe_metadata(mod)) end)
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
end
