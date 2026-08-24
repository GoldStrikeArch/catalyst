defmodule Catalyst.LLM.ProviderConfig do
  @moduledoc """
  Describes a registered LLM provider (Catalyst's analog of PI's `ProviderConfig`).

  Stored in `Catalyst.LLM.Registry` keyed by the model `api` string. `module` is
  the `Catalyst.LLM.Provider` implementation that does the actual streaming;
  `name` is display metadata for the UI/session. Optional `controls` implements
  `Catalyst.LLM.Controls`, allowing a provider to contribute model-picker and
  authentication behavior without feature-specific shell branches. Wire details
  live on `Catalyst.Model` and the provider module itself.
  """

  @enforce_keys [:module]
  defstruct [:module, :name, :controls]

  @type t :: %__MODULE__{
          module: module(),
          name: String.t() | nil,
          controls: module() | nil
        }
end
