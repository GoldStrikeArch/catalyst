defmodule Catalyst.OwnedIndex do
  @moduledoc """
  Pure bidirectional ownership index for runtime registries.

  Registries keep their values in their own storage and use this module only
  for collision checks and owner-scoped cleanup. This deliberately does not
  prescribe validation, fallback, or error semantics for those registries.
  """

  @enforce_keys [:by_owner, :by_key]
  defstruct by_owner: %{}, by_key: %{}

  @typedoc "An ownership index whose keys and owners are registry-defined terms."
  @type t :: %__MODULE__{
          by_owner: %{optional(term()) => MapSet.t(term())},
          by_key: %{optional(term()) => term()}
        }

  @doc "Create an empty ownership index."
  @spec new() :: t()
  def new, do: %__MODULE__{by_owner: %{}, by_key: %{}}

  @doc "Return the owner of `key`, or `nil` when unclaimed; use `fetch_owner/2` if `nil` is a valid owner."
  @spec owner(t(), term()) :: term() | nil
  def owner(%__MODULE__{by_key: by_key}, key), do: Map.get(by_key, key)

  @doc "Fetch the owner of `key` without conflating an unclaimed key with owner `nil`."
  @spec fetch_owner(t(), term()) :: {:ok, term()} | :error
  def fetch_owner(%__MODULE__{by_key: by_key}, key), do: Map.fetch(by_key, key)

  @doc "Return the keys tracked for `owner`."
  @spec keys(t(), term()) :: MapSet.t(term())
  def keys(%__MODULE__{by_owner: by_owner}, owner) do
    Map.get(by_owner, owner, MapSet.new())
  end

  @doc """
  Claim `key` for `owner`.

  Reclaiming a key by the same owner is idempotent. A different owner returns
  `{:error, existing_owner}`. Set `track_owner: false` for host registrations
  which must participate in collision checks but not owner-wide purges.
  """
  @spec claim(t(), term(), term(), keyword()) :: {:ok, t()} | {:error, term()}
  def claim(index, key, owner, opts \\ [])

  def claim(%__MODULE__{} = index, key, owner, opts) do
    case fetch_owner(index, key) do
      :error -> {:ok, put(index, key, owner, opts)}
      {:ok, ^owner} -> {:ok, put(index, key, owner, opts)}
      {:ok, existing_owner} -> {:error, existing_owner}
    end
  end

  @doc "Release one key and remove empty owner buckets."
  @spec release(t(), term()) :: t()
  def release(%__MODULE__{} = index, key) do
    case Map.fetch(index.by_key, key) do
      :error ->
        index

      {:ok, owner} ->
        by_key = Map.delete(index.by_key, key)
        %__MODULE__{index | by_key: by_key, by_owner: drop_owner_key(index, owner, key)}
    end
  end

  @doc """
  Release every key tracked for `owner`.

  Returns the released keys together with the updated index so callers can
  remove the corresponding values from their own storage.
  """
  @spec release_owner(t(), term()) :: {MapSet.t(term()), t()}
  def release_owner(%__MODULE__{} = index, owner) do
    owned_keys = keys(index, owner)

    by_key =
      Enum.reduce(owned_keys, index.by_key, fn key, acc ->
        case Map.fetch(acc, key) do
          {:ok, ^owner} -> Map.delete(acc, key)
          _other -> acc
        end
      end)

    {owned_keys, %__MODULE__{index | by_owner: Map.delete(index.by_owner, owner), by_key: by_key}}
  end

  defp put(index, key, owner, opts) do
    index = release(index, key)
    by_key = Map.put(index.by_key, key, owner)

    case Keyword.get(opts, :track_owner, true) do
      true ->
        owner_keys = index |> keys(owner) |> MapSet.put(key)
        %__MODULE__{index | by_key: by_key, by_owner: Map.put(index.by_owner, owner, owner_keys)}

      false ->
        %__MODULE__{index | by_key: by_key}
    end
  end

  defp drop_owner_key(index, owner, key) do
    owner_keys = index |> keys(owner) |> MapSet.delete(key)

    case MapSet.size(owner_keys) do
      0 -> Map.delete(index.by_owner, owner)
      _count -> Map.put(index.by_owner, owner, owner_keys)
    end
  end
end
