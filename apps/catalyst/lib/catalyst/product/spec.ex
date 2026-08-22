defmodule Catalyst.Product.Spec do
  @moduledoc "Validated initial composition for one compiled Catalyst product."

  @enforce_keys [:id, :packs, :tools, :hosts]
  defstruct @enforce_keys

  @hosts [:cli, :web, :desktop]

  @type host :: :cli | :web | :desktop
  @type t :: %__MODULE__{
          id: String.t(),
          packs: [String.t()],
          tools: [module()],
          hosts: [host()]
        }

  @doc "Build and validate a product specification."
  @spec new(map() | keyword()) :: {:ok, t()} | {:error, term()}
  def new(attrs) when is_list(attrs), do: attrs |> Map.new() |> new()
  def new(%__MODULE__{} = spec), do: validate(spec)

  def new(attrs) when is_map(attrs) do
    attrs |> then(&struct(__MODULE__, &1)) |> validate()
  rescue
    error in [ArgumentError, KeyError] -> {:error, {:invalid_product_spec, error}}
  end

  def new(attrs), do: {:error, {:invalid_product_spec, attrs}}

  @doc "Build a product specification, raising for invalid compiled data."
  @spec new!(map() | keyword()) :: t()
  def new!(attrs) do
    case new(attrs) do
      {:ok, spec} -> spec
      {:error, reason} -> raise ArgumentError, "invalid product spec: #{inspect(reason)}"
    end
  end

  @doc "Read a modern `spec/0` profile or adapt a legacy `id/0` + `tools/0` profile."
  @spec from_profile(module()) :: {:ok, t()} | {:error, term()}
  def from_profile(profile) when is_atom(profile) do
    with true <- Code.ensure_loaded?(profile) do
      profile
      |> profile_attrs()
      |> new()
    else
      false -> {:error, {:invalid_product_profile, profile}}
    end
  rescue
    error -> {:error, {:invalid_product_profile, profile, error}}
  catch
    kind, reason -> {:error, {:invalid_product_profile, profile, kind, reason}}
  end

  def from_profile(profile), do: {:error, {:invalid_product_profile, profile}}

  defp validate(spec) do
    with :ok <- validate_id(spec.id),
         :ok <- validate_list(:packs, spec.packs, &valid_id?/1),
         :ok <- Catalyst.Pack.Registry.validate_product_packs(spec.packs),
         :ok <- validate_list(:tools, spec.tools, &module?/1),
         :ok <- validate_list(:hosts, spec.hosts, &(&1 in @hosts)),
         :ok <- validate_pack_hosts(spec.packs, spec.hosts) do
      {:ok, spec}
    end
  end

  defp validate_pack_hosts(pack_ids, hosts) do
    with {:ok, packs} <- Catalyst.Pack.Registry.resolve(pack_ids) do
      incompatible =
        for pack <- packs,
            host <- hosts,
            host not in pack.hosts,
            do: {pack.id, host}

      case incompatible do
        [] -> :ok
        _incompatible -> {:error, {:incompatible_product_pack_hosts, incompatible}}
      end
    end
  end

  defp profile_attrs(profile) do
    case function_exported?(profile, :spec, 0) do
      true -> profile.spec()
      false -> %{id: profile.id(), packs: [], tools: profile.tools(), hosts: [:cli]}
    end
  end

  defp validate_id(id) do
    case valid_id?(id) do
      true -> :ok
      false -> {:error, {:invalid_product_id, id}}
    end
  end

  defp validate_list(field, values, validator) when is_list(values) do
    case Enum.all?(values, validator) and length(values) == MapSet.size(MapSet.new(values)) do
      true -> :ok
      false -> {:error, {:invalid_product_field, field, values}}
    end
  end

  defp validate_list(field, values, _validator),
    do: {:error, {:invalid_product_field, field, values}}

  defp valid_id?(value) when is_binary(value) do
    value != "" and byte_size(value) <= 128 and
      String.match?(value, ~r/\A[a-z0-9][a-z0-9._-]*\z/)
  end

  defp valid_id?(_value), do: false

  defp module?(value),
    do: is_atom(value) and String.starts_with?(Atom.to_string(value), "Elixir.")
end
