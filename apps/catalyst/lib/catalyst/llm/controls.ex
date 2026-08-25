defmodule Catalyst.LLM.Controls do
  @moduledoc """
  Optional model-picker and authentication metadata for an LLM provider.

  Providers register a controls module through `Catalyst.LLM.ProviderConfig`.
  The web shell can then present any provider without compiling feature-specific
  branches into the kernel UI.
  """

  alias Catalyst.Model

  @doc "Stable provider id stored in shell preferences and catalog entries."
  @callback id() :: String.t()

  @doc "Default model id selected for a new shell session."
  @callback default_model_id() :: String.t()

  @doc "Models exposed by this provider in the model picker."
  @callback list_models() :: [map()]

  @doc "Catalog entry for an id, including a renderable unknown-id fallback."
  @callback catalog_entry(String.t()) :: map()

  @doc "Build the runtime model selected by id."
  @callback model(String.t()) :: Model.t()

  @doc "Default reasoning effort for this provider."
  @callback default_effort() :: String.t()

  @doc "Token-store provider id used for login state and logout."
  @callback auth_provider() :: String.t()

  @doc "Human-facing subscription name."
  @callback auth_label() :: String.t()

  @doc "Run this provider's interactive sign-in flow."
  @callback login() :: {:ok, String.t() | nil} | {:error, term()}

  @doc "Refresh credentials previously issued by this provider."
  @callback refresh_auth(map()) :: {:ok, map()} | {:error, term()}

  @doc "Translate provider-neutral shell preferences into session run options."
  @callback run_opts(map()) :: keyword()

  @doc "Callbacks a controls module must export."
  @spec callbacks() :: [{atom(), non_neg_integer()}]
  def callbacks do
    [
      id: 0,
      default_model_id: 0,
      list_models: 0,
      catalog_entry: 1,
      model: 1,
      default_effort: 0,
      auth_provider: 0,
      auth_label: 0,
      login: 0,
      refresh_auth: 1,
      run_opts: 1
    ]
  end
end
