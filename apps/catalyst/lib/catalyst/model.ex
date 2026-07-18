defmodule Catalyst.Model do
  @moduledoc """
  Provider-agnostic model descriptor. `api` selects the provider implementation
  via `Catalyst.LLM.Registry`; `provider`/`base_url` carry the wire details.
  """
  @enforce_keys [:id, :api]
  defstruct [
    :id,
    :name,
    :api,
    :provider,
    :base_url,
    reasoning: false,
    input: [:text],
    context_window: nil,
    max_context_window: nil,
    effective_context_window_percent: nil,
    auto_compact_token_limit: nil,
    context_window_source: nil,
    max_tokens: nil
  ]

  @type t :: %__MODULE__{
          id: String.t(),
          name: String.t() | nil,
          api: String.t(),
          provider: String.t() | nil,
          base_url: String.t() | nil,
          reasoning: boolean(),
          input: [:text | :image],
          context_window: pos_integer() | nil,
          max_context_window: pos_integer() | nil,
          effective_context_window_percent: number() | nil,
          auto_compact_token_limit: pos_integer() | nil,
          context_window_source: :session | :catalog | :persisted | :fallback | nil,
          max_tokens: pos_integer() | nil
        }
end
