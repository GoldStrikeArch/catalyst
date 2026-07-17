defmodule Catalyst.LLM.Provider do
  @moduledoc """
  Behaviour every LLM provider implements.

  `stream/4` runs one model turn, calling `sink` with `Catalyst.LLM.Event`s as
  tokens/tool-calls arrive, and returns the final assistant message.

  Contract (ported from PI's `StreamFn`): **never raise** for request/model/
  runtime failures — encode them as a final `Catalyst.Message.Assistant` with
  `stop_reason: :error | :aborted` and return `{:ok, assistant}` (the loop
  inspects `stop_reason`). Reserve `{:error, term}` for programmer errors.
  """

  @type sink :: (Catalyst.LLM.Event.t() -> any())

  @callback stream(
              model :: Catalyst.Model.t(),
              context :: Catalyst.LLM.Context.t(),
              opts :: keyword(),
              sink :: sink()
            ) :: {:ok, Catalyst.Message.Assistant.t()} | {:error, term()}

  @callback cleanup_session(session_id :: String.t()) :: :ok

  @optional_callbacks cleanup_session: 1
end
