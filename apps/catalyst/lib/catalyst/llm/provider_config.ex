defmodule Catalyst.LLM.ProviderConfig do
  @moduledoc """
  Describes a registered LLM provider (Catalyst's analog of PI's `ProviderConfig`).

  Stored in `Catalyst.LLM.Registry` keyed by the model `api` string. `module` is
  the `Catalyst.LLM.Provider` implementation that does the actual streaming; the
  rest is metadata the UI/session can use (display name, endpoint, auth scheme,
  and the models this provider offers).
  """

  @enforce_keys [:module]
  defstruct [:module, :name, :base_url, headers: %{}, auth: nil, models: []]

  @type auth :: %{required(:kind) => :oauth | :api_key | :none, optional(atom()) => any()} | nil

  @type t :: %__MODULE__{
          module: module(),
          name: String.t() | nil,
          base_url: String.t() | nil,
          headers: map(),
          auth: auth(),
          models: [Catalyst.Model.t()]
        }
end
