defmodule Catalyst.Session.Effect do
  @moduledoc """
  A bounded side-effect request returned by a pure session engine.

  Engines cannot execute arbitrary callbacks through this type. The stable
  session host validates and interprets each effect while retaining ownership of
  tasks, persistence, broadcasting, and runtime resources.
  """

  @enforce_keys [:kind, :payload]
  defstruct @enforce_keys

  @type kind :: :start_run | :stop_run | :emit
  @type t :: %__MODULE__{kind: kind(), payload: term()}

  @doc "Request that the host start one run with the supplied user messages."
  @spec start_run([Catalyst.Message.User.t()]) :: t()
  def start_run(messages) when is_list(messages),
    do: %__MODULE__{kind: :start_run, payload: messages}

  @doc "Request that the host stop and clear its current run resources."
  @spec stop_run(term()) :: t()
  def stop_run(reason \\ :engine_request),
    do: %__MODULE__{kind: :stop_run, payload: reason}

  @doc "Request a synthetic host-owned event emission."
  @spec emit(term()) :: t()
  def emit(event), do: %__MODULE__{kind: :emit, payload: event}

  @doc "Validate one effect before the host interprets it."
  @spec validate(t()) :: :ok | {:error, term()}
  def validate(%__MODULE__{kind: :start_run, payload: messages}) when is_list(messages) do
    case Enum.all?(messages, &match?(%Catalyst.Message.User{}, &1)) do
      true -> :ok
      false -> {:error, :invalid_start_run_messages}
    end
  end

  def validate(%__MODULE__{kind: :stop_run}), do: :ok
  def validate(%__MODULE__{kind: :emit}), do: :ok
  def validate(%__MODULE__{} = effect), do: {:error, {:unsupported_session_effect, effect.kind}}
end
