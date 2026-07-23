defmodule Catalyst.LLM.ProviderConfig do
  @moduledoc """
  Describes a registered LLM provider (Catalyst's analog of PI's `ProviderConfig`).

  Stored in `Catalyst.LLM.Registry` keyed by the model `api` string. `module` is
  the `Catalyst.LLM.Provider` implementation that does the actual streaming;
  `name` is display metadata for the UI/session. Wire details (endpoint, auth)
  live on `Catalyst.Model` and the provider module itself.
  """

  @enforce_keys [:module]
  defstruct [:module, :name]

  @type t :: %__MODULE__{
          module: module(),
          name: String.t() | nil
        }
end
