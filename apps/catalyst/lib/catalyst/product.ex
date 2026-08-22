defmodule Catalyst.Product do
  @moduledoc """
  Access to the product profile that supplies Catalyst's initial composition.

  Runtime claims may replace this composition after boot. The profile owns
  product choices while registries retain validation and lookup mechanics.
  """

  @type profile :: module()

  @doc "Validated initial composition supplied by a modern product profile."
  @callback spec() :: Catalyst.Product.Spec.t()

  @doc "Stable identifier for a product composition."
  @callback id() :: String.t()

  @doc "Tool modules installed by a product composition."
  @callback tools() :: [module()]

  @optional_callbacks spec: 0, id: 0, tools: 0

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
      {:ok, profile} -> %{id: spec!(profile).id, module: profile, source: :application}
      :error -> Catalyst.Product.Selection.active()
    end
  end

  @doc "Return the validated initial composition for the active product."
  @spec active_spec() :: Catalyst.Product.Spec.t()
  def active_spec, do: spec!(profile())

  @doc "Persist an allow-listed product profile for the next boot."
  @spec select(String.t()) :: {:ok, :restart_required} | {:error, term()}
  defdelegate select(id), to: Catalyst.Product.Selection

  @doc "Return the configured product identifier."
  @spec id() :: String.t()
  def id, do: active_spec().id

  @doc "Return the product's default tool modules."
  @spec tools() :: [module()]
  def tools, do: active_spec().tools

  defp spec!(profile) do
    case Catalyst.Product.Spec.from_profile(profile) do
      {:ok, spec} -> spec
      {:error, reason} -> raise ArgumentError, "invalid product profile: #{inspect(reason)}"
    end
  end
end
