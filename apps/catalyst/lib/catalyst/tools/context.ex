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

  Invariant: `session_id == parent_session_id` at all times. Only `new/1` and
  the `Access` callbacks maintain that sync — build contexts with `new/1` and
  update either key through `Access` (`put_in`/`update_in`), never with a
  direct struct update like `%{ctx | session_id: ...}`, which would desync the
  aliased fields.
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
  def get_and_update(context, :session_id, fun) do
    update_parent_id(context, fun)
  end

  def get_and_update(context, :parent_session_id, fun) do
    update_parent_id(context, fun)
  end

  def get_and_update(context, key, fun) do
    case Map.has_key?(context, key) do
      true -> update_field(context, key, fun)
      false -> raise KeyError, key: key, term: context
    end
  end

  @impl Access
  def pop(context, :session_id), do: pop_parent_id(context)

  def pop(context, :parent_session_id), do: pop_parent_id(context)

  def pop(context, key) do
    case Map.has_key?(context, key) do
      true -> {Map.fetch!(context, key), Map.put(context, key, nil)}
      false -> {nil, context}
    end
  end

  defp update_parent_id(context, fun) do
    current = context.parent_session_id

    case fun.(current) do
      :pop ->
        {current, sync_parent_id(context, nil)}

      {get, update} ->
        {get, sync_parent_id(context, update)}

      other ->
        raise "the Access callback must return {get, update} or :pop, got: #{inspect(other)}"
    end
  end

  defp pop_parent_id(context) do
    {context.parent_session_id, sync_parent_id(context, nil)}
  end

  defp sync_parent_id(context, parent_id) do
    %{context | session_id: parent_id, parent_session_id: parent_id}
  end

  defp update_field(context, key, fun) do
    current = Map.fetch!(context, key)

    case fun.(current) do
      :pop ->
        {current, Map.put(context, key, nil)}

      {get, update} ->
        {get, Map.put(context, key, update)}

      other ->
        raise "the Access callback must return {get, update} or :pop, got: #{inspect(other)}"
    end
  end
end
