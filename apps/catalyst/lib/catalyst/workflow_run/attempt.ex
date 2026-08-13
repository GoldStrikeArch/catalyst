defmodule Catalyst.WorkflowRun.Attempt do
  @moduledoc """
  Boundary for one explicitly supervised workflow-stage attempt.

  Implementations perform the actual child-agent work. They receive a JSON-safe
  context map and a transient event emitter. Returning `{:retry, reason}` asks
  the coordinator to apply the stage's retry limit; `{:error, reason}` is
  terminal. Results and reasons must be JSON-encodable.
  """

  @type json_value ::
          nil | boolean() | number() | String.t() | [json_value()] | %{String.t() => json_value()}
  @type context :: %{required(String.t()) => json_value()}
  @type emitter :: (term() -> any())
  @type result ::
          {:ok, json_value()}
          | {:retry, json_value()}
          | {:error, json_value()}
          | {:cancelled, json_value()}

  @doc "Execute one stage attempt."
  @callback run(context(), emitter()) :: result()
end
