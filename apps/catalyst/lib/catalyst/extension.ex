defmodule Catalyst.Extension do
  @moduledoc """
  Behaviour for a Catalyst extension — the unified, multi-kind plug-in entry
  point (Catalyst's analog of PI's `ExtensionFactory = (pi) => void`).

  An extension is a module with a `setup/1` callback. When its source file is
  loaded (`Catalyst.Extensions.load_file/1`), Catalyst calls `setup/1` with a
  `Catalyst.ExtensionAPI` struct through which the extension registers any mix of
  tools, loop hooks, event observers, LLM providers, and UI renderers/components/
  pages/commands:

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

  @callback setup(api :: Catalyst.ExtensionAPI.t()) :: :ok | {:error, term()}

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
end
