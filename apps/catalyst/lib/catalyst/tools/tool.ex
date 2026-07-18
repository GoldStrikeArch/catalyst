defmodule Catalyst.Tools.Tool do
  @moduledoc """
  Behaviour for agent tools (PI's `ToolDefinition`).

  `execute/2` receives the validated args map and a `ctx` carrying the working
  directory, the tool-call id, and a `report` callback for streaming partial
  results (PI's `onUpdate`). It returns a result map, or **raises** to signal an
  error — `Catalyst.Agent.ToolRunner` turns a raise/exit into an error
  tool-result, mirroring PI's "thrown exceptions become error results".
  """

  alias Catalyst.Content

  @type result :: %{content: [Content.t()], details: map(), terminate: boolean()}
  @type ctx :: %{
          required(:cwd) => String.t(),
          required(:call_id) => String.t(),
          required(:report) => (result() -> :ok),
          optional(atom()) => any()
        }

  @doc "Return the stable provider-visible name used to resolve tool calls."
  @callback name() :: String.t()

  @doc "Return the provider-visible description of when and how to use the tool."
  @callback description() :: String.t()

  @doc "Return the JSON Schema map used to validate tool-call arguments."
  @callback parameters() :: map()

  @doc """
  Execute one validated call.

  Use `ctx.report/1` for partial updates. Expected tool failures may raise or
  exit; the runner converts them into error tool results.
  """
  @callback execute(args :: map(), ctx :: ctx()) :: result()

  @doc """
  Return whether calls to this tool may execute concurrently.

  This callback is optional and defaults to `:parallel` for modules using this
  behaviour's `__using__/1` macro.
  """
  @callback execution_mode() :: :parallel | :sequential

  @optional_callbacks execution_mode: 0

  defmacro __using__(_opts) do
    quote do
      @behaviour Catalyst.Tools.Tool
      @before_compile Catalyst.Tools.Tool
      import Catalyst.Tools.Tool, only: [result: 1, result: 2]

      @doc false
      def execution_mode, do: :parallel
      defoverridable execution_mode: 0
    end
  end

  @doc false
  defmacro __before_compile__(_env) do
    quote do
      # A local capture remains bound to this exact BEAM generation. The tool
      # registry records it beside the matching schema and execution mode, so
      # a hot reload cannot make an already-assembled batch call new code under
      # stale metadata.
      @doc false
      def __catalyst_executor__, do: &execute/2
    end
  end

  @doc """
  Build a text result with optional structured `details` for programmatic
  consumers (hooks, UIs, tests). Never terminates the loop (`terminate: false`).
  """
  @spec result(String.t(), map()) :: result()
  def result(text, details \\ %{}) when is_binary(text) do
    %{content: [%Content.Text{text: text}], details: details, terminate: false}
  end
end
