defmodule Catalyst.Tools.Context do
  @moduledoc """
  Explicit execution context passed to tools by `Catalyst.Agent.ToolRunner`.

  Besides the existing `cwd`, `call_id`, and progress reporter, this carries the
  parent/root session identity and the already-sanitized configuration a core
  tool may inherit into a child session. The original `tool_source` selector is
  retained separately from the concrete tool list resolved for the current
  turn, so a child can keep live `:extensions` semantics.

  The struct implements `Access` for compatibility with extension tools that
  historically treated the context as a map. `session_id` is retained as a real
  field kept in sync with `parent_session_id`, so `Map.get/2`, map access, and
  `ctx[:session_id]` all see the parent id.

  Invariant: `session_id == parent_session_id` at all times. Only `new/1`
  maintains that sync — contexts are read-only after construction. The `Access`
  read (`ctx[:session_id]`) is a published compatibility promise; the write
  callbacks (`put_in`/`update_in`/`pop_in`) raise, because a written context is
  never observed by the run that produced it and a direct struct update like
  `%{ctx | session_id: ...}` would desync the aliased fields.
  """

  @behaviour Access

  @enforce_keys [:cwd, :call_id, :report]
  defstruct [
    :cwd,
    :session_id,
    :parent_session_id,
    :root_session_id,
    :model,
    :provider,
    :workflow,
    :tool_source,
    :call_id,
    :report,
    opts: [],
    agent_depth: 0
  ]

  @type t :: %__MODULE__{
          cwd: String.t(),
          session_id: String.t() | nil,
          parent_session_id: String.t() | nil,
          root_session_id: String.t() | nil,
          model: Catalyst.Model.t() | nil,
          provider: module() | String.t() | nil,
          opts: keyword(),
          workflow: term(),
          tool_source: term(),
          agent_depth: non_neg_integer(),
          call_id: String.t(),
          report: (Catalyst.Tools.Tool.result() -> :ok)
        }

  @doc "Build a tool context, accepting the historical `:session_id` as the parent id."
  @spec new(keyword()) :: t()
  def new(opts) when is_list(opts) do
    parent_id = Keyword.get(opts, :parent_session_id, Keyword.get(opts, :session_id))
    root_id = Keyword.get(opts, :root_session_id) || parent_id

    struct!(__MODULE__,
      cwd: Keyword.fetch!(opts, :cwd),
      session_id: parent_id,
      parent_session_id: parent_id,
      root_session_id: root_id,
      model: Keyword.get(opts, :model),
      provider: Keyword.get(opts, :provider),
      opts: Keyword.get(opts, :opts, []),
      workflow: Keyword.get(opts, :workflow),
      tool_source: Keyword.get(opts, :tool_source),
      agent_depth: Keyword.get(opts, :agent_depth, 0),
      call_id: Keyword.fetch!(opts, :call_id),
      report: Keyword.fetch!(opts, :report)
    )
  end

  @impl Access
  def fetch(context, key), do: Map.fetch(context, key)

  @impl Access
  def get_and_update(_context, key, _fun) do
    raise ArgumentError,
          "Catalyst.Tools.Context is read-only after new/1; " <>
            "cannot put_in/update_in key #{inspect(key)}"
  end

  @impl Access
  def pop(_context, key) do
    raise ArgumentError,
          "Catalyst.Tools.Context is read-only after new/1; cannot pop key #{inspect(key)}"
  end
end
