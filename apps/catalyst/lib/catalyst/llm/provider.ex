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

  @doc """
  Stream one model turn and return its final assistant message.

  Deliver incremental `Catalyst.LLM.Event` values to `sink`. Request, model,
  authentication, and transport failures must return an error/aborted assistant
  inside `{:ok, assistant}`; reserve `{:error, reason}` for programmer errors.

  `model` may be `nil` (a session can run before any model is configured —
  `RunConfig` declares `Model.t() | nil`); providers must tolerate it, as
  `Faux` does with its `model && model.id` guard.
  """
  @callback stream(
              model :: Catalyst.Model.t() | nil,
              context :: Catalyst.LLM.Context.t(),
              opts :: keyword(),
              sink :: sink()
            ) :: {:ok, Catalyst.Message.Assistant.t()} | {:error, term()}

  @doc "Release provider resources retained for a session; optional providers may omit it."
  @callback cleanup_session(session_id :: String.t()) :: :ok

  @doc """
  Return a stable fingerprint of the exact provider-visible request semantics.

  Generated transport values such as replay ids must not affect the result.
  Return `:unsupported` when the provider cannot supply an exact projection.
  """
  @callback context_fingerprint(
              model :: Catalyst.Model.t() | nil,
              context :: Catalyst.LLM.Context.t(),
              opts :: keyword()
            ) :: {:ok, binary()} | :unsupported

  @doc """
  Estimate the tokens in the exact provider-visible request projection.

  Return `:unsupported` to use Catalyst's provider-neutral coarse estimate.
  """
  @callback estimate_tokens(
              model :: Catalyst.Model.t() | nil,
              context :: Catalyst.LLM.Context.t(),
              opts :: keyword()
            ) :: {:ok, non_neg_integer()} | :unsupported

  @optional_callbacks cleanup_session: 1, context_fingerprint: 3, estimate_tokens: 3
end
