defmodule Catalyst.LLM.ModelCatalog do
  @moduledoc """
  Contract for a provider-owned model catalog.

  Catalogs return picker metadata separately from the `%Catalyst.Model{}` used
  for a request. A snapshot must include the selected entry in `:models`, even
  when the selected id is no longer in the provider's current catalog.
  """

  alias Catalyst.Model

  @typedoc "Provider-owned picker metadata. Every entry must have an id."
  @type entry :: %{required(:id) => String.t(), optional(atom()) => term()}

  @typedoc "One consistent catalog read and its selected entry."
  @type snapshot :: %{models: [entry()], selected: entry()}

  @doc "Read the catalog and resolve `id` from the same snapshot."
  @callback catalog_snapshot(id :: String.t()) :: snapshot()

  @doc "Build the request model for `id`."
  @callback model(id :: String.t()) :: Model.t()

  @doc "The provider's default model id."
  @callback default_model_id() :: String.t()
end
