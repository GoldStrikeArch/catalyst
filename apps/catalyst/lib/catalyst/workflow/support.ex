defmodule Catalyst.Workflow.Support do
  @moduledoc """
  Shared lifecycle helpers for conforming workflows.

  The built-in loop and extension workflows use this module so observer
  delivery, live tool selection, depth capabilities, and request-time context
  guarding do not drift apart. Calling a provider module directly is an
  unsupported bypass of these guarantees.
  """

  alias Catalyst.Agent.Event
  alias Catalyst.{Debug, Hooks, Message}
  alias Catalyst.Context.Guard
  alias Catalyst.Tools.Profiles
  alias Catalyst.Tools.Registry, as: ToolRegistry

  @default_subagent_max_depth 3
  @default_tool_profile "coding"

  @doc "Build, transform, account for, and compact one ordinary request when needed."
  @spec prepare_request(map(), map(), (Event.t() -> any()), keyword() | map()) ::
          {:ok, Guard.prepared()} | {:error, term()}
  def prepare_request(context, config, emit, opts \\ []) do
    Guard.prepare_request(context, config, emit, opts)
  end

  @doc "Wrap an event sink so every event is also offered to ordered observers."
  @spec observed_emit((Event.t() -> any()), map()) :: (Event.t() -> any())
  def observed_emit(emit, config) when is_function(emit, 1) and is_map(config) do
    observer_key = option(config, :session_id, self())
    observed(emit, observer_key)
  end

  defp observed(emit, session_key) when is_function(emit, 1) do
    fn event ->
      Debug.log_event(debug_session_id(session_key), event)
      Hooks.notify(event, session_key)
      emit.(event)
    end
  end

  defp debug_session_id(session_id) when is_binary(session_id), do: session_id
  defp debug_session_id(_session_key), do: nil

  @doc "Resolve the original live tool source, then apply final capability and profile filtering."
  @spec resolve_tools(map()) :: [module()]
  def resolve_tools(config) when is_map(config) do
    config
    |> tool_source()
    |> Catalyst.Extensions.resolve()
    |> filter_capabilities(config)
    |> Profiles.filter(tool_profile(config))
  end

  @doc "Return a turn config with one validated tool index and its exact provider definitions."
  @spec resolve_turn_tools(map()) :: map()
  def resolve_turn_tools(config) when is_map(config) do
    source = tool_source(config)
    tools = resolve_tools(config)
    modules = MapSet.new(tools)

    index =
      source
      |> Catalyst.Extensions.tool_index()
      |> Map.filter(fn {_name, entry} -> MapSet.member?(modules, entry.module) end)

    config
    |> Map.put(:tool_source, source)
    |> Map.put(:tools, tools)
    |> Map.put(:tool_index, index)
  end

  @doc """
  Apply non-bypassable capability limits after every tool source is resolved.

  Two rules run in order: `spawn_agent` is stripped at the subagent depth cap,
  then any tool declaring a capability this run does not grant is dropped.
  Because this runs after `Catalyst.Extensions.resolve/1`, neither an explicit
  `tools:` list nor an extension registration can add a gated tool back.
  """
  @spec filter_capabilities([module()], map()) :: [module()]
  def filter_capabilities(tools, config) when is_list(tools) and is_map(config) do
    tools
    |> reject_at_depth_limit(config)
    |> reject_ungranted(config)
  end

  @doc """
  The capabilities this run grants, as declared by tools' `capabilities/0`.

  Capability definitions come from the shared extension registry. The kernel
  does not know which optional capabilities exist.
  """
  @spec granted_capabilities(map()) :: [atom()]
  def granted_capabilities(config) when is_map(config), do: Catalyst.Capabilities.granted(config)

  @doc "Return the unexpanded selector retained for child-session inheritance."
  @spec tool_source(map()) :: term()
  def tool_source(config) when is_map(config) do
    case Map.fetch(config, :tool_source) do
      {:ok, source} -> source
      :error -> Map.get(config, :tools, :extensions)
    end
  end

  @doc """
  Return the canonical persisted tool profile for a run.

  Missing values retain the original coding behavior. Invalid values are
  returned as-is so the final profile filter fails closed.
  """
  @spec tool_profile(map()) :: term()
  def tool_profile(config) when is_map(config) do
    profile = option(config, :tool_profile, @default_tool_profile)

    case Profiles.normalize(profile) do
      {:ok, normalized} -> normalized
      :error -> profile
    end
  end

  @doc "Whether the current run has reached its configured subagent depth cap."
  @spec at_subagent_depth_limit?(map()) :: boolean()
  def at_subagent_depth_limit?(config) when is_map(config) do
    depth = non_negative(option(config, :agent_depth, 0), 0)

    max_depth =
      config
      |> option(
        :subagent_max_depth,
        Application.get_env(:catalyst, :subagent_max_depth, @default_subagent_max_depth)
      )
      |> non_negative(@default_subagent_max_depth)

    depth >= max_depth
  end

  @doc """
  Make one ordinary provider request through the context-guard seam.

  The default path prepares the exact request with `Context.Guard`, streams the
  prepared provider context, and returns the prepared value alongside the
  provider outcome as `{:ok, assistant, prepared}`. Provider failures return
  `{:error, reason, prepared}` so a workflow can keep an accepted compaction in
  its local context. Guard failures return the guard's ordinary
  `{:error, reason}`.

  The fifth argument is reserved for internal requests such as compaction:
  `guard: false` deliberately bypasses recursive guarding and retains the
  provider's `{:ok, assistant} | {:error, reason}` contract. A module supplied
  as `guard: MyGuard` is useful for isolated implementations and tests and must
  implement the same `prepare_request/4` contract as `Context.Guard`.
  """
  @spec request_provider(
          Catalyst.Model.t() | nil,
          term(),
          map(),
          (Event.t() -> any()),
          keyword()
        ) :: term()
  def request_provider(model, context, config, emit, opts \\ [])
      when is_map(config) and is_function(emit, 1) and is_list(opts) do
    case guard_module(opts) do
      false -> stream_provider(model, context, config, emit)
      {:error, _reason} = error -> error
      guard -> guarded_request(guard, model, context, config, emit, opts)
    end
  end

  defp guarded_request(guard, model, context, config, emit, opts) do
    config = Map.put(config, :model, model)

    with {:ok, prepared} <- call_guard(guard, context, config, emit, opts) do
      case stream_provider(model, prepared.llm_context, config, emit) do
        {:ok, %Message.Assistant{} = assistant} ->
          {:ok, assistant, prepared}

        {:ok, assistant} ->
          {:ok, assistant, prepared}

        {:error, reason} ->
          {:error, reason, prepared}

        invalid ->
          {:error, {:invalid_provider_return, invalid}, prepared}
      end
    end
  end

  defp call_guard(guard, context, config, emit, opts) do
    case Code.ensure_loaded?(guard) and function_exported?(guard, :prepare_request, 4) do
      true -> apply(guard, :prepare_request, [context, config, emit, guard_options(config, opts)])
      false -> {:error, {:invalid_context_guard, guard}}
    end
  end

  defp guard_options(config, opts) do
    opts
    |> Keyword.delete(:guard)
    |> Keyword.put_new(:register_resource, Map.get(config, :register_resource))
    |> Keyword.put_new(:persist_event, Map.get(config, :persist_event))
    |> Keyword.put_new(:session_id, option(config, :session_id, nil))
    |> Keyword.put_new(:cwd, Map.get(config, :cwd))
  end

  defp stream_provider(model, context, config, emit) do
    sink = fn llm_event -> emit.(%Event.MessageUpdate{llm_event: llm_event}) end

    case Map.get(config, :provider) do
      provider when is_atom(provider) and not is_nil(provider) ->
        provider.stream(model, context, Map.get(config, :opts, []), sink)

      provider ->
        {:error, {:invalid_provider, provider}}
    end
  end

  defp guard_module(opts) do
    case Keyword.get(opts, :guard, true) do
      false -> false
      nil -> false
      true -> context_guard_module()
      module when is_atom(module) -> module
      invalid -> {:error, {:invalid_context_guard, invalid}}
    end
  end

  # Resolve these optional runtime seams without compile-time module attributes;
  # otherwise xref connects Workflow.Support back into the modules that use it.
  defp context_guard_module, do: Module.concat(["Catalyst", "Context", "Guard"])
  defp spawn_agent_module, do: Module.concat(["Catalyst", "Tools", "SpawnAgent"])

  defp option(config, key, default) do
    case Map.fetch(config, key) do
      {:ok, value} -> value
      :error -> nested_option(config, key, default)
    end
  end

  defp nested_option(config, key, default) do
    case Map.get(config, :opts, []) do
      opts when is_list(opts) -> Keyword.get(opts, key, default)
      opts when is_map(opts) -> Map.get(opts, key, default)
      _invalid -> default
    end
  end

  defp non_negative(value, _default) when is_integer(value) and value >= 0, do: value
  defp non_negative(_value, default), do: default

  defp reject_at_depth_limit(tools, config) do
    case at_subagent_depth_limit?(config) do
      true -> Enum.reject(tools, &(&1 == spawn_agent_module()))
      false -> tools
    end
  end

  # Capabilities come from the fingerprint-keyed registry cache, so no
  # extension callback runs on the turn-assembly path. Both sides are tiny
  # lists (most tools declare none), so a plain membership test is right.
  defp reject_ungranted(tools, config) do
    granted = granted_capabilities(config)

    Enum.reject(tools, fn module ->
      module |> ToolRegistry.capabilities_of() |> Enum.any?(&(&1 not in granted))
    end)
  end
end
