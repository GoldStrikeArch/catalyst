defmodule Catalyst.Contracts.Workbench.V1 do
  @moduledoc """
  Version-one pure state/effects contract for a mounted web workbench.

  The stable host owns the Phoenix socket, forms, navigation, filesystem access,
  uploads, and asynchronous tasks. Implementations own only JSON-serializable
  state and return validated effects for the host to interpret.
  """

  alias Catalyst.Runtime.ContractRef

  @max_state_bytes 4_194_304
  @max_effects 32

  @type state :: map()
  @type context :: map()
  @type request_id :: String.t()
  @type effect ::
          {:workspace, :list, request_id()}
          | {:workspace, :read, request_id(), Path.t()}
          | {:workspace, :write, request_id(), Path.t(), String.t()}
          | {:command, :run, request_id(), String.t()}
          | {:navigate, String.t()}
  @type transition :: {:ok, state(), [effect()]} | {:error, term()}
  @type capsule :: %{version: pos_integer(), payload: term()}

  @doc "Initialize serializable workbench state and declarative host effects."
  @callback mount(context()) :: transition()

  @doc "Handle one namespaced browser event without accessing the Phoenix socket."
  @callback event(String.t(), map(), state(), context()) :: transition()

  @doc "Handle one host-owned effect result or routed process message."
  @callback info(term(), state(), context()) :: transition()

  @doc "Return the ID of a function component registered with the web host."
  @callback render_target(state()) :: String.t()

  @doc "Return raw named form values; the stable host constructs Phoenix forms."
  @callback forms(state()) :: %{optional(atom()) => map()}

  @doc "Create a bounded, versioned capsule for controlled workbench replacement."
  @callback snapshot(state()) :: {:ok, capsule()} | {:error, term()}

  @doc "Restore a capsule into a new workbench generation."
  @callback restore(capsule(), context()) :: transition()

  @optional_callbacks snapshot: 1, restore: 2

  @doc "Return the stable Runtime Graph contract reference."
  @spec ref() :: ContractRef.t()
  def ref, do: ContractRef.new!("catalyst.workbench", 1)

  @doc "Validate and normalize a callback transition."
  @spec validate_transition(term()) :: transition()
  def validate_transition({:ok, state, effects}) when is_map(state) and is_list(effects) do
    with :ok <- serializable_state(state),
         :ok <- validate_effects(effects) do
      {:ok, state, effects}
    end
  end

  def validate_transition({:error, _reason} = error), do: error
  def validate_transition(result), do: {:error, {:invalid_workbench_transition, result}}

  @doc "Validate effects accepted by the stable workbench host."
  @spec validate_effects([term()]) :: :ok | {:error, term()}
  def validate_effects(effects) when is_list(effects) do
    with :ok <- validate_effect_count(effects),
         :ok <- validate_effect_shapes(effects) do
      validate_request_ids(effects)
    end
  end

  def validate_effects(effects), do: {:error, {:invalid_workbench_effects, effects}}

  @doc "Validate a versioned workbench handoff capsule."
  @spec validate_capsule(term()) :: {:ok, capsule()} | {:error, term()}
  def validate_capsule(%{version: version, payload: _payload} = capsule)
      when is_integer(version) and version > 0 do
    case Jason.encode(capsule) do
      {:ok, json} when byte_size(json) <= @max_state_bytes -> {:ok, capsule}
      {:ok, json} -> {:error, {:workbench_capsule_too_large, byte_size(json), @max_state_bytes}}
      {:error, reason} -> {:error, {:invalid_workbench_capsule, reason}}
    end
  end

  def validate_capsule(capsule), do: {:error, {:invalid_workbench_capsule, capsule}}

  defp serializable_state(state) do
    case Jason.encode(state) do
      {:ok, json} when byte_size(json) <= @max_state_bytes -> :ok
      {:ok, json} -> {:error, {:workbench_state_too_large, byte_size(json), @max_state_bytes}}
      {:error, reason} -> {:error, {:invalid_workbench_state, reason}}
    end
  end

  defp validate_effect_count(effects) when length(effects) <= @max_effects, do: :ok

  defp validate_effect_count(effects),
    do: {:error, {:too_many_workbench_effects, length(effects), @max_effects}}

  defp validate_effect_shapes(effects) do
    case Enum.find(effects, &(not valid_effect?(&1))) do
      nil -> :ok
      invalid -> {:error, {:invalid_workbench_effect, invalid}}
    end
  end

  defp validate_request_ids(effects) do
    ids = Enum.flat_map(effects, &request_ids/1)

    case ids -- Enum.uniq(ids) do
      [] -> :ok
      duplicates -> {:error, {:duplicate_workbench_effect_ids, Enum.uniq(duplicates)}}
    end
  end

  defp request_ids({:workspace, :list, request_id}), do: [request_id]
  defp request_ids({:workspace, :read, request_id, _path}), do: [request_id]
  defp request_ids({:workspace, :write, request_id, _path, _content}), do: [request_id]
  defp request_ids({:command, :run, request_id, _command}), do: [request_id]
  defp request_ids({:navigate, _location}), do: []

  defp valid_effect?({:workspace, :list, request_id}), do: valid_request_id?(request_id)

  defp valid_effect?({:workspace, :read, request_id, path}),
    do: valid_request_id?(request_id) and valid_text?(path, 4_096)

  defp valid_effect?({:workspace, :write, request_id, path, content}),
    do:
      valid_request_id?(request_id) and valid_text?(path, 4_096) and
        valid_binary?(content, 1_048_576)

  defp valid_effect?({:command, :run, request_id, command}),
    do: valid_request_id?(request_id) and valid_text?(command, 8_192)

  defp valid_effect?({:navigate, "/" <> _path = location}),
    do: byte_size(location) <= 4_096 and not String.starts_with?(location, "//")

  defp valid_effect?(_effect), do: false

  defp valid_request_id?(value), do: valid_text?(value, 128)

  defp valid_text?(value, limit),
    do: is_binary(value) and byte_size(value) > 0 and byte_size(value) <= limit

  defp valid_binary?(value, limit), do: is_binary(value) and byte_size(value) <= limit
end
