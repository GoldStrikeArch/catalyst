defmodule Catalyst.Product do
  @moduledoc """
  Access to the product profile that supplies Catalyst's initial composition.

  Runtime claims may replace this composition after boot. The profile owns
  product choices while registries retain validation and lookup mechanics.
  """

  @type profile :: module()

  @composition_key {__MODULE__, :composition}

  @doc "Validated initial composition supplied by a modern product profile."
  @callback spec() :: Catalyst.Product.Spec.t()

  @doc "Stable identifier for a product composition."
  @callback id() :: String.t()

  @doc "Tool modules installed by a product composition."
  @callback tools() :: [module()]

  @optional_callbacks spec: 0, id: 0, tools: 0

  @doc "Pin the selected product composition for this application boot."
  @spec initialize!() :: :ok
  def initialize! do
    case :persistent_term.get(@composition_key, :missing) do
      :missing -> :persistent_term.put(@composition_key, build_composition!())
      %Catalyst.Product.Composition{} -> :ok
    end

    :ok
  end

  @doc "Return the immutable composition selected for this application boot."
  @spec composition() :: Catalyst.Product.Composition.t()
  def composition do
    :ok = initialize!()
    :persistent_term.get(@composition_key)
  end

  @doc "Return the configured product profile module."
  @spec profile() :: profile()
  def profile, do: composition().profile

  @doc "Describe the active product profile and how it was selected."
  @spec active() :: %{id: String.t(), module: module(), source: atom()}
  def active do
    composition = composition()
    %{id: composition.spec.id, module: composition.profile, source: composition.source}
  end

  @doc "Return the validated initial composition for the active product."
  @spec active_spec() :: Catalyst.Product.Spec.t()
  def active_spec, do: composition().spec

  @doc "Persist an allow-listed product profile for the next boot."
  @spec select(String.t()) :: {:ok, :restart_required} | {:error, term()}
  defdelegate select(id), to: Catalyst.Product.Selection

  @doc "Return the configured product identifier."
  @spec id() :: String.t()
  def id, do: active_spec().id

  @doc "Return the product's default tool modules."
  @spec tools() :: [module()]
  def tools, do: active_spec().tools

  @doc false
  @spec reset_for_test() :: :ok
  def reset_for_test do
    :persistent_term.erase(@composition_key)
    :ok
  end

  defp build_composition! do
    selection = configured_selection()

    case Catalyst.Product.Composition.build(selection) do
      {:ok, composition} -> composition
      {:error, reason} -> raise ArgumentError, "invalid product composition: #{inspect(reason)}"
    end
  end

  defp configured_selection do
    case Application.fetch_env(:catalyst, :product_profile) do
      {:ok, profile} -> %{module: profile, source: :application}
      :error -> Catalyst.Product.Selection.active()
    end
  end
end
