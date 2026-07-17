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

  @callback name() :: String.t()
  @callback description() :: String.t()
  @callback parameters() :: map()
  @callback execute(args :: map(), ctx :: ctx()) :: result()
  @callback execution_mode() :: :parallel | :sequential

  @optional_callbacks execution_mode: 0

  defmacro __using__(_opts) do
    quote do
      @behaviour Catalyst.Tools.Tool
      import Catalyst.Tools.Tool, only: [result: 1, result: 2]

      @doc false
      def execution_mode, do: :parallel
      defoverridable execution_mode: 0
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
