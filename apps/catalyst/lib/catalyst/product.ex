defmodule Catalyst.Product do
  @moduledoc """
  Access to the product profile that supplies Catalyst's initial composition.

  Runtime claims may replace this composition after boot. The profile owns
  product choices while registries retain validation and lookup mechanics.
  """

  @type profile :: module()

  @doc "Stable identifier for a product composition."
  @callback id() :: String.t()

  @doc "Tool modules installed by a product composition."
  @callback tools() :: [module()]

  @doc "Return the configured product profile module."
  @spec profile() :: profile()
  def profile, do: Application.get_env(:catalyst, :product_profile, Catalyst.Product.Default)

  @doc "Return the configured product identifier."
  @spec id() :: String.t()
  def id, do: profile().id()

  @doc "Return the product's default tool modules."
  @spec tools() :: [module()]
  def tools, do: profile().tools()
end
