defmodule Catalyst.Contracts.Workbench.V1 do
  @moduledoc """
  Version-one pure state/effects contract for a mounted web workbench.

  The stable host owns the Phoenix socket, forms, navigation, filesystem access,
  uploads, and asynchronous tasks. Implementations own only JSON-serializable
  state and return validated effects for the host to interpret.
  """

  alias Catalyst.Runtime.ContractRef

  @max_state_bytes 268_435_456
  @max_effects 32
  @max_client_payload_bytes 1_048_576

  @type state :: map()
  @type context :: map()
  @type request_id :: String.t()
  @type session_prompt ::
          String.t()
          | %{
              required(String.t()) => String.t() | [map()]
            }
  @type effect ::
          {:workspace, :list, request_id()}
          | {:workspace, :read, request_id(), Path.t()}
          | {:workspace, :write, request_id(), Path.t(), String.t()}
          | {:workspace, :search, request_id(), String.t()}
          | {:command, :run, request_id(), String.t()}
          | {:models, :list, request_id()}
          | {:session, :open, request_id()}
          | {:session, :open, request_id(), map()}
          | {:session, :submit, request_id(), String.t(), session_prompt()}
          | {:session, :abort, request_id(), String.t()}
          | {:session, :snapshot, request_id(), String.t()}
          | {:session, :list, request_id(), String.t() | nil}
          | {:session, :attach, request_id(), String.t()}
          | {:session, :close, request_id(), String.t()}
          | {:session, :configure, request_id(), String.t(), map()}
          | {:auth, :login, request_id(), String.t()}
          | {:auth, :logout, request_id(), String.t()}
          | {:client, :push, String.t(), map()}
          | {:navigate, String.t()}
  @type transition :: {:ok, state(), [effect()]} | {:error, term()}
  @type capsule :: %{version: pos_integer(), payload: term()}
  @type render_target :: String.t() | {module(), atom()}

  @doc "Initialize serializable workbench state and declarative host effects."
  @callback mount(context()) :: transition()

  @doc "Handle one namespaced browser event without accessing the Phoenix socket."
  @callback event(String.t(), map(), state(), context()) :: transition()

  @doc "Handle one host-owned effect result or routed process message."
  @callback info(term(), state(), context()) :: transition()

  @doc """
  Return a legacy registered component ID or the exact local implementation's
  own `{module, function}` component.

  Built-ins and managed artifacts may use direct targets. The stable host rejects
  a direct target unless its module is the exact implementation pinned by the
  Workbench Runtime Handle.
  """
  @callback render_target(state()) :: render_target()

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

  @doc """
  Validate a transition while avoiding a full re-encode when state is unchanged.

  This is used for bounded client-push effects such as streaming deltas. Changed
  state still receives the complete serializability and size validation.
  """
  @spec validate_transition(term(), state()) :: transition()
  def validate_transition({:ok, state, effects}, state) when is_map(state) and is_list(effects) do
    case validate_effects(effects) do
      :ok -> {:ok, state, effects}
      {:error, _reason} = error -> error
    end
  end

  def validate_transition(result, _previous_state), do: validate_transition(result)

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
  defp request_ids({:workspace, :search, request_id, _query}), do: [request_id]
  defp request_ids({:command, :run, request_id, _command}), do: [request_id]
  defp request_ids({:models, :list, request_id}), do: [request_id]
  defp request_ids({:session, :open, request_id}), do: [request_id]
  defp request_ids({:session, :open, request_id, _settings}), do: [request_id]
  defp request_ids({:session, :submit, request_id, _session_id, _input}), do: [request_id]
  defp request_ids({:session, :abort, request_id, _session_id}), do: [request_id]
  defp request_ids({:session, :snapshot, request_id, _session_id}), do: [request_id]
  defp request_ids({:session, :list, request_id, _session_id}), do: [request_id]
  defp request_ids({:session, :attach, request_id, _session_id}), do: [request_id]
  defp request_ids({:session, :close, request_id, _session_id}), do: [request_id]

  defp request_ids({:session, :configure, request_id, _session_id, _settings}),
    do: [request_id]

  defp request_ids({:auth, operation, request_id, _provider})
       when operation in [:login, :logout],
       do: [request_id]

  defp request_ids({:client, :push, _event, _payload}), do: []
  defp request_ids({:navigate, _location}), do: []

  defp valid_effect?({:workspace, :list, request_id}), do: valid_request_id?(request_id)

  defp valid_effect?({:workspace, :read, request_id, path}),
    do: valid_request_id?(request_id) and valid_text?(path, 4_096)

  defp valid_effect?({:workspace, :write, request_id, path, content}),
    do:
      valid_request_id?(request_id) and valid_text?(path, 4_096) and
        valid_binary?(content, 1_048_576)

  defp valid_effect?({:workspace, :search, request_id, query}),
    do: valid_request_id?(request_id) and valid_binary?(query, 4_096)

  defp valid_effect?({:command, :run, request_id, command}),
    do: valid_request_id?(request_id) and valid_text?(command, 8_192)

  defp valid_effect?({:models, :list, request_id}), do: valid_request_id?(request_id)

  defp valid_effect?({:session, :open, request_id}), do: valid_request_id?(request_id)

  defp valid_effect?({:session, :open, request_id, settings}),
    do: valid_request_id?(request_id) and valid_session_settings?(settings)

  defp valid_effect?({:session, :submit, request_id, session_id, prompt}),
    do:
      valid_request_id?(request_id) and valid_text?(session_id, 128) and
        valid_session_prompt?(prompt)

  defp valid_effect?({:session, :abort, request_id, session_id}),
    do: valid_request_id?(request_id) and valid_text?(session_id, 128)

  defp valid_effect?({:session, :snapshot, request_id, session_id}),
    do: valid_request_id?(request_id) and valid_text?(session_id, 128)

  defp valid_effect?({:session, :list, request_id, session_id}),
    do:
      valid_request_id?(request_id) and
        (is_nil(session_id) or valid_text?(session_id, 128))

  defp valid_effect?({:session, operation, request_id, session_id})
       when operation in [:attach, :close],
       do: valid_request_id?(request_id) and valid_text?(session_id, 128)

  defp valid_effect?({:session, :configure, request_id, session_id, settings}),
    do:
      valid_request_id?(request_id) and valid_text?(session_id, 128) and
        valid_session_settings?(settings)

  defp valid_effect?({:auth, operation, request_id, provider})
       when operation in [:login, :logout],
       do: valid_request_id?(request_id) and valid_text?(provider, 128)

  defp valid_effect?({:client, :push, "workbench:" <> _suffix = event, payload})
       when is_map(payload) do
    valid_text?(event, 128) and serializable_client_payload?(payload)
  end

  defp valid_effect?({:navigate, "/" <> _path = location}),
    do: byte_size(location) <= 4_096 and not String.starts_with?(location, "//")

  defp valid_effect?(_effect), do: false

  defp valid_request_id?(value), do: valid_text?(value, 128)

  defp valid_text?(value, limit),
    do: is_binary(value) and byte_size(value) > 0 and byte_size(value) <= limit

  defp valid_binary?(value, limit), do: is_binary(value) and byte_size(value) <= limit

  defp valid_session_settings?(settings) when is_map(settings) do
    Enum.all?(settings, fn
      {key, value} when is_binary(key) ->
        valid_session_setting_key?(key) and valid_session_setting_value?(value)

      _invalid ->
        false
    end)
  end

  defp valid_session_settings?(_settings), do: false

  defp valid_session_setting_key?("provider"), do: true
  defp valid_session_setting_key?("model"), do: true
  defp valid_session_setting_key?("cwd"), do: true
  defp valid_session_setting_key?("effort"), do: true
  defp valid_session_setting_key?("fast"), do: true
  defp valid_session_setting_key?("transport"), do: true
  defp valid_session_setting_key?("workflow"), do: true
  defp valid_session_setting_key?("quiet"), do: true
  defp valid_session_setting_key?("computer_use"), do: true
  defp valid_session_setting_key?(_key), do: false

  defp valid_session_setting_value?(value) when is_binary(value),
    do: byte_size(value) <= 4_096

  defp valid_session_setting_value?(value) when is_boolean(value) or is_nil(value), do: true
  defp valid_session_setting_value?(_value), do: false

  defp valid_session_prompt?(prompt) when is_binary(prompt),
    do: valid_text?(prompt, 262_144)

  defp valid_session_prompt?(%{"text" => text, "images" => images})
       when is_binary(text) and is_list(images) and length(images) <= 4 do
    valid_binary?(text, 262_144) and Enum.all?(images, &valid_prompt_image?/1) and
      (text != "" or images != [])
  end

  defp valid_session_prompt?(_prompt), do: false

  defp valid_prompt_image?(%{"data" => data, "mime_type" => mime_type}),
    do:
      valid_binary?(data, 7_000_000) and
        mime_type in ~w(image/png image/jpeg image/gif image/webp)

  defp valid_prompt_image?(_image), do: false

  defp serializable_client_payload?(payload) do
    case Jason.encode(payload) do
      {:ok, json} -> byte_size(json) <= @max_client_payload_bytes
      {:error, _reason} -> false
    end
  end
end
