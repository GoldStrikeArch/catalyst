defmodule Catalyst.LLM.ProviderConfig do
  @moduledoc """
  Describes a registered LLM provider (Catalyst's analog of PI's `ProviderConfig`).

  Stored in `Catalyst.LLM.Registry` keyed by the model `api` string. `module` is
  the `Catalyst.LLM.Provider` implementation that does the actual streaming.
  The optional descriptor fields let catalog-aware consumers discover models
  without importing a concrete provider. Legacy registrations only need
  `module` and remain valid.
  """

  @enforce_keys [:module]
  defstruct [:module, :id, :name, :catalog, :auth, controls: %{}, catalog_priority: 500]

  @type t :: %__MODULE__{
          module: module(),
          id: String.t() | nil,
          name: String.t() | nil,
          catalog: module() | nil,
          auth: module() | nil,
          controls: map(),
          catalog_priority: integer()
        }
end
