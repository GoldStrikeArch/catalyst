defmodule Catalyst.Runtime.ExtensionPoint do
  @moduledoc """
  Owner-scoped declaration of one runtime contribution or service boundary.

  Extension points describe accepted payloads; they do not require one central
  storage or execution process. Host-owned points may delegate activation to a
  subsystem handler. Extension-defined points are declarative and are stored by
  `Catalyst.Runtime.ExtensionPoints` until a subsystem consumes them.
  """

  alias Catalyst.Runtime.{ContractRef, ServiceKey}

  @enforce_keys [:id, :cardinality, :owner, :provenance]
  defstruct @enforce_keys ++
              [
                contract: nil,
                service: nil,
                default_binding: :live,
                schema: nil,
                resolved_schema: nil,
                handler: nil,
                metadata: %{}
              ]

  @type cardinality :: :one | :many
  @type service_identity :: {String.t(), String.t()}
  @type handler :: {module(), atom()}

  @type t :: %__MODULE__{
          id: String.t(),
          cardinality: cardinality(),
          owner: term(),
          provenance: term(),
          contract: ContractRef.t() | nil,
          service: service_identity() | nil,
          default_binding: Catalyst.Runtime.Claim.binding(),
          schema: map() | nil,
          resolved_schema: term(),
          handler: handler() | nil,
          metadata: map()
        }

  @doc "Build and validate an extension-point declaration."
  @spec new(map() | keyword(), term(), term(), handler() | nil) ::
          {:ok, t()} | {:error, term()}
  def new(spec, owner, provenance, handler \\ nil) do
    spec = normalize_spec(spec)

    with :ok <- validate_id(spec[:id]),
         :ok <- validate_cardinality(spec[:cardinality]),
         :ok <- validate_contract(spec[:contract]),
         :ok <- validate_service(spec[:service], spec[:contract]),
         :ok <- validate_binding(spec[:default_binding]),
         {:ok, resolved_schema} <- resolve_schema(spec[:schema]),
         :ok <- validate_handler(handler),
         :ok <- validate_metadata(spec[:metadata]) do
      {:ok,
       %__MODULE__{
         id: spec.id,
         cardinality: spec.cardinality,
         owner: owner,
         provenance: provenance,
         contract: spec.contract,
         service: spec.service,
         default_binding: spec.default_binding,
         schema: spec.schema,
         resolved_schema: resolved_schema,
         handler: handler,
         metadata: spec.metadata
       }}
    end
  end

  @doc "Whether this point declares the service family containing `key`."
  @spec service?(t(), Catalyst.Runtime.ServiceKey.t()) :: boolean()
  def service?(
        %__MODULE__{service: {namespace, name}},
        %Catalyst.Runtime.ServiceKey{namespace: namespace, name: name}
      ),
      do: true

  def service?(%__MODULE__{}, %Catalyst.Runtime.ServiceKey{}), do: false

  defp normalize_spec(spec) when is_list(spec), do: spec |> Map.new() |> normalize_spec()

  defp normalize_spec(spec) when is_map(spec) do
    %{
      id: Map.get(spec, :id),
      cardinality: Map.get(spec, :cardinality, :many),
      contract: Map.get(spec, :contract),
      service: Map.get(spec, :service),
      default_binding: Map.get(spec, :default_binding, :live),
      schema: Map.get(spec, :schema),
      metadata: Map.get(spec, :metadata, %{})
    }
  end

  defp normalize_spec(spec), do: %{id: spec}

  defp validate_id(id) when is_binary(id) and byte_size(id) > 0 do
    case String.trim(id) do
      ^id -> :ok
      _trimmed -> {:error, {:invalid_extension_point_id, id}}
    end
  end

  defp validate_id(id), do: {:error, {:invalid_extension_point_id, id}}

  defp validate_cardinality(cardinality) when cardinality in [:one, :many], do: :ok

  defp validate_cardinality(cardinality),
    do: {:error, {:invalid_extension_point_cardinality, cardinality}}

  defp validate_contract(nil), do: :ok
  defp validate_contract(%ContractRef{}), do: :ok
  defp validate_contract(contract), do: {:error, {:invalid_extension_point_contract, contract}}

  defp validate_service(nil, _contract), do: :ok

  defp validate_service({namespace, name}, %ContractRef{}) do
    case ServiceKey.new(namespace, name) do
      {:ok, _key} -> :ok
      {:error, reason} -> {:error, {:invalid_extension_point_service, {namespace, name}, reason}}
    end
  end

  defp validate_service(service, contract),
    do: {:error, {:invalid_extension_point_service, service, contract}}

  defp validate_binding(:live), do: :ok
  defp validate_binding({:pin, lifetime}) when is_atom(lifetime), do: :ok
  defp validate_binding(binding), do: {:error, {:invalid_extension_point_binding, binding}}

  defp resolve_schema(nil), do: {:ok, nil}

  defp resolve_schema(schema) when is_map(schema) do
    resolved =
      schema
      |> Jason.encode!()
      |> Jason.decode!()
      |> ExJsonSchema.Schema.resolve()

    {:ok, resolved}
  rescue
    exception -> {:error, {:invalid_extension_point_schema, exception}}
  catch
    kind, reason -> {:error, {:invalid_extension_point_schema, {kind, reason}}}
  end

  defp resolve_schema(schema), do: {:error, {:invalid_extension_point_schema, schema}}

  defp validate_handler(nil), do: :ok

  defp validate_handler({module, function}) when is_atom(module) and is_atom(function), do: :ok

  defp validate_handler(handler), do: {:error, {:invalid_extension_point_handler, handler}}

  defp validate_metadata(metadata) when is_map(metadata), do: :ok
  defp validate_metadata(metadata), do: {:error, {:invalid_extension_point_metadata, metadata}}
end
