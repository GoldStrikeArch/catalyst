defmodule Catalyst.Workflow.Attempt.SessionAdapter do
  @moduledoc """
  Session boundary used by `Catalyst.Workflow.Attempt`.

  Implementations start or resume a child session, subscribe the calling
  process to its events, and control the active run. The behaviour keeps
  workflow orchestration testable without a provider or persisted session.
  """

  @type session :: %{id: String.t(), pid: pid()}

  @doc "Start an exclusively-created child session."
  @callback start_fresh(keyword()) :: {:ok, session()} | {:error, term()}

  @doc "Start or adopt the persisted child session identified by `opts[:id]`."
  @callback resume(keyword()) :: {:ok, session()} | {:error, term()}

  @doc "Subscribe the caller to events for `session_id`."
  @callback subscribe(String.t()) :: :ok | {:error, term()}

  @doc "Remove the caller's event subscription."
  @callback unsubscribe(String.t()) :: :ok

  @doc "Start one child run with the explicit stage prompt."
  @callback prompt(pid(), String.t()) :: :ok | {:error, term()}

  @doc "Abort the child session's active run."
  @callback abort(pid()) :: :ok

  @doc "Stop the live child process while retaining its transcript."
  @callback stop(String.t()) :: :ok | {:error, term()}
end
