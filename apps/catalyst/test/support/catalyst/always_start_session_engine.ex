defmodule Catalyst.Test.AlwaysStartSessionEngine do
  @moduledoc false

  @behaviour Catalyst.Contracts.SessionEngine.V2

  alias Catalyst.Session.{DefaultEngineV2, Effect}

  @impl true
  defdelegate init(context), to: DefaultEngineV2

  @impl true
  def command({:prompt, message, _status}, state, private),
    do: {:ok, state, private, [Effect.start_run([message])], :ok}

  def command(command, state, private), do: DefaultEngineV2.command(command, state, private)

  @impl true
  defdelegate event(envelope, state, private), to: DefaultEngineV2

  @impl true
  defdelegate aborted_tool_results(state, private, reason), to: DefaultEngineV2

  @impl true
  defdelegate failure_message(state, private, reason), to: DefaultEngineV2

  @impl true
  defdelegate state_version(), to: DefaultEngineV2

  @impl true
  defdelegate snapshot(state, private), to: DefaultEngineV2

  @impl true
  defdelegate restore(capsule), to: DefaultEngineV2

  @impl true
  defdelegate verify_handoff(capsule, state, private), to: DefaultEngineV2
end
