defmodule Catalyst.Product.Composition do
  @moduledoc """
  Immutable, validated product composition selected for one application boot.

  The composition pins both the product specification and the dependency-
  ordered pack manifests. Runtime overrides may layer on top of this baseline,
  but application configuration and the durable profile pointer are not
  re-read until the next boot.
  """

  alias Catalyst.Pack.{Manifest, Registry}
  alias Catalyst.Product.Spec

  @enforce_keys [:profile, :source, :spec, :packs, :digest]
  defstruct @enforce_keys

  @type source :: :application | :persisted | :default | :fallback
  @type selection :: %{required(:module) => module(), required(:source) => source()}
  @type t :: %__MODULE__{
          profile: module(),
          source: source(),
          spec: Spec.t(),
          packs: [Manifest.t()],
          digest: String.t()
        }

  @doc "Build a validated composition from one resolved profile selection."
  @spec build(selection()) :: {:ok, t()} | {:error, term()}
  def build(%{module: profile, source: source}) when is_atom(profile) do
    with {:ok, spec} <- Spec.from_profile(profile),
         {:ok, packs} <- Registry.resolve(spec.packs) do
      {:ok,
       %__MODULE__{
         profile: profile,
         source: source,
         spec: spec,
         packs: packs,
         digest: digest(spec, packs)
       }}
    end
  end

  def build(selection), do: {:error, {:invalid_product_selection, selection}}

  @doc "Return the compiled pack that declares a provider API, if present."
  @spec provider_pack(t(), String.t()) :: {:ok, Manifest.t()} | :error
  def provider_pack(%__MODULE__{packs: packs}, api) when is_binary(api) do
    Enum.find_value(packs, :error, fn manifest ->
      case Enum.any?(manifest.services, &provider_service?(&1, api)) do
        true -> {:ok, manifest}
        false -> false
      end
    end)
  end

  defp provider_service?(%{kind: :llm_provider, api: api}, api), do: true
  defp provider_service?(_service, _api), do: false

  defp digest(spec, packs) do
    %{spec: spec, packs: packs}
    |> :erlang.term_to_binary([:deterministic])
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end
end
