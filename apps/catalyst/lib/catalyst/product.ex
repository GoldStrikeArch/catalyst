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
  def profile do
    case Application.fetch_env(:catalyst, :product_profile) do
      {:ok, profile} -> profile
      :error -> Catalyst.Product.Selection.active().module
    end
  end

  @doc "Describe the active product profile and how it was selected."
  @spec active() :: %{id: String.t(), module: module(), source: atom()}
  def active do
    case Application.fetch_env(:catalyst, :product_profile) do
      {:ok, profile} -> %{id: profile.id(), module: profile, source: :application}
      :error -> Catalyst.Product.Selection.active()
    end
  end

  @doc "Persist an allow-listed product profile for the next boot."
  @spec select(String.t()) :: {:ok, :restart_required} | {:error, term()}
  defdelegate select(id), to: Catalyst.Product.Selection

  @doc "Return the configured product identifier."
  @spec id() :: String.t()
  def id, do: profile().id()

  @doc "Return the product's default tool modules."
  @spec tools() :: [module()]
  def tools, do: profile().tools()
end
