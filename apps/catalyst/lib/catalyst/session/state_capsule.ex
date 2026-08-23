defmodule Catalyst.Session.StateCapsule do
  @moduledoc """
  Bounded, checksummed state passed between session-engine generations.

  Capsules contain semantic data only. PIDs, ports, references, functions, task
  handles, store handles, and runtime leases are rejected recursively.
  """

  @enforce_keys [
    :contract,
    :state_version,
    :source,
    :payload,
    :checksum,
    :created_at
  ]
  defstruct @enforce_keys ++ [metadata: %{}]

  alias Catalyst.Runtime.{ContractRef, ImplementationRef}

  @type t :: %__MODULE__{
          contract: ContractRef.t(),
          state_version: pos_integer(),
          source: term(),
          payload: term(),
          checksum: String.t(),
          created_at: DateTime.t(),
          metadata: map()
        }

  @doc "Create and validate one bounded session-engine state capsule."
  @spec new(ContractRef.t(), pos_integer(), term(), term(), keyword()) ::
          {:ok, t()} | {:error, term()}
  def new(contract, state_version, source, payload, opts \\ [])

  def new(%ContractRef{} = contract, state_version, source, payload, opts)
      when is_integer(state_version) and state_version > 0 and is_list(opts) do
    metadata = Keyword.get(opts, :metadata, %{})
    logical_source = ImplementationRef.logical(source)
    content = content(contract, state_version, logical_source, payload, metadata)

    with :ok <- validate_safe(content),
         {:ok, encoded} <- encode_bounded(content, Keyword.get(opts, :max_bytes, max_bytes())) do
      {:ok,
       %__MODULE__{
         contract: contract,
         state_version: state_version,
         source: logical_source,
         payload: payload,
         checksum: checksum(encoded),
         created_at: DateTime.utc_now(),
         metadata: metadata
       }}
    end
  end

  def new(%ContractRef{}, state_version, _source, _payload, _opts),
    do: {:error, {:invalid_state_version, state_version}}

  @doc "Verify the capsule checksum, safety constraints, and current size bound."
  @spec verify(t()) :: :ok | {:error, term()}
  def verify(%__MODULE__{} = capsule) do
    content =
      content(
        capsule.contract,
        capsule.state_version,
        capsule.source,
        capsule.payload,
        capsule.metadata
      )

    with :ok <- validate_safe(content),
         {:ok, encoded} <- encode_bounded(content, max_bytes()),
         true <- checksum(encoded) == capsule.checksum do
      :ok
    else
      false -> {:error, :state_capsule_checksum_mismatch}
      {:error, _reason} = error -> error
    end
  end

  defp content(contract, state_version, source, payload, metadata),
    do: {contract, state_version, source, payload, metadata}

  defp encode_bounded(content, max_bytes) do
    encoded = :erlang.term_to_binary(content, [:deterministic])

    case byte_size(encoded) <= max_bytes do
      true -> {:ok, encoded}
      false -> {:error, {:state_capsule_too_large, byte_size(encoded), max_bytes}}
    end
  end

  defp checksum(encoded),
    do: encoded |> then(&:crypto.hash(:sha256, &1)) |> Base.encode16(case: :lower)

  defp max_bytes,
    do: Application.get_env(:catalyst, :session_state_capsule_max_bytes, 8 * 1_024 * 1_024)

  defp validate_safe(content) do
    case unsafe_term?(content) do
      true -> {:error, :unsafe_state_capsule}
      false -> :ok
    end
  end

  defp unsafe_term?(term) when is_pid(term) or is_port(term) or is_reference(term), do: true
  defp unsafe_term?(term) when is_function(term), do: true
  defp unsafe_term?(term) when is_list(term), do: Enum.any?(term, &unsafe_term?/1)

  defp unsafe_term?(term) when is_tuple(term),
    do: term |> Tuple.to_list() |> Enum.any?(&unsafe_term?/1)

  defp unsafe_term?(term) when is_map(term) do
    term
    |> Map.to_list()
    |> Enum.any?(fn {key, value} -> unsafe_term?(key) or unsafe_term?(value) end)
  end

  defp unsafe_term?(_term), do: false
end
