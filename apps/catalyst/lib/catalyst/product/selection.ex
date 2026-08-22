defmodule Catalyst.Product.Selection do
  @moduledoc """
  Durable selection of a known compiled product profile.

  The file stores a stable profile id, never an atom or module name. Resolution
  maps that id through the host's configured profile allow-list and falls back
  to the default coding-agent profile when the file is absent or invalid.
  """

  alias Catalyst.Files.AtomicWrite

  @builtins [
    {"coding-agent", Catalyst.Product.Default},
    {"minimal-cli", Catalyst.Product.MinimalCLI},
    {"ide", Catalyst.Product.IDE}
  ]

  @doc "Return the selected profile module and the source of that decision."
  @spec active() :: %{id: String.t(), module: module(), source: :persisted | :default | :fallback}
  def active do
    profiles = profiles()

    case read_id() do
      {:ok, id} -> selected(id, profiles)
      :error -> default(:default)
    end
  end

  @doc "Persist a known profile id for the next application boot."
  @spec select(String.t()) :: {:ok, :restart_required} | {:error, term()}
  def select(id) when is_binary(id) and id != "" do
    with {:ok, _profile} <- fetch(id),
         :ok <- File.mkdir_p(Path.dirname(path())),
         :ok <- AtomicWrite.write(path(), id <> "\n") do
      {:ok, :restart_required}
    end
  end

  def select(id), do: {:error, {:unknown_product_profile, id}}

  @doc "Return the allow-listed compiled product profiles by stable id."
  @spec profiles() :: %{String.t() => module()}
  def profiles do
    case build_profiles(Application.get_env(:catalyst, :product_profiles, %{})) do
      {:ok, profiles} -> profiles
      {:error, reason} -> raise ArgumentError, "invalid product profiles: #{inspect(reason)}"
    end
  end

  @doc "Build a profile allow-list and reject duplicate stable identifiers."
  @spec build_profiles(map() | [{String.t(), module()}]) ::
          {:ok, %{String.t() => module()}} | {:error, term()}
  def build_profiles(configured) when is_map(configured),
    do: build_profiles(Map.to_list(configured))

  def build_profiles(configured) when is_list(configured) do
    entries = @builtins ++ configured

    with :ok <- validate_entries(entries),
         :ok <- reject_duplicate_ids(entries) do
      {:ok, Map.new(entries)}
    end
  end

  def build_profiles(configured), do: {:error, {:invalid_product_profiles, configured}}

  @doc "Resolve one allow-listed profile id without creating atoms."
  @spec fetch(String.t()) :: {:ok, module()} | {:error, {:unknown_product_profile, String.t()}}
  def fetch(id) when is_binary(id) do
    case Map.fetch(profiles(), id) do
      {:ok, profile} -> validate_profile(id, profile)
      :error -> {:error, {:unknown_product_profile, id}}
    end
  end

  @doc "Path to the durable profile pointer."
  @spec path() :: Path.t()
  def path, do: Catalyst.Paths.product_profile()

  defp selected(id, profiles) do
    case Map.fetch(profiles, id) do
      {:ok, profile} -> validate_selected(id, profile)
      :error -> default(:fallback)
    end
  end

  defp validate_selected(id, profile) do
    case validate_profile(id, profile) do
      {:ok, profile} -> %{id: id, module: profile, source: :persisted}
      {:error, _reason} -> default(:fallback)
    end
  end

  defp default(source) do
    %{id: "coding-agent", module: Catalyst.Product.Default, source: source}
  end

  defp read_id do
    case File.read(path()) do
      {:ok, contents} -> normalize_id(contents)
      {:error, _reason} -> :error
    end
  end

  defp normalize_id(contents) do
    case String.trim(contents) do
      "" -> :error
      id -> {:ok, id}
    end
  end

  defp validate_profile(id, profile) when is_atom(profile) do
    case Catalyst.Product.Spec.from_profile(profile) do
      {:ok, %{id: ^id}} -> {:ok, profile}
      _invalid -> {:error, {:unknown_product_profile, id}}
    end
  end

  defp validate_profile(id, _profile), do: {:error, {:unknown_product_profile, id}}

  defp validate_entries(entries) do
    case Enum.all?(entries, fn
           {id, profile} -> is_binary(id) and id != "" and is_atom(profile)
           _entry -> false
         end) do
      true -> :ok
      false -> {:error, {:invalid_product_profiles, entries}}
    end
  end

  defp reject_duplicate_ids(entries) do
    duplicates =
      entries
      |> Enum.frequencies_by(&elem(&1, 0))
      |> Enum.flat_map(fn
        {id, count} when count > 1 -> [id]
        {_id, _count} -> []
      end)
      |> Enum.sort()

    case duplicates do
      [] -> :ok
      _duplicates -> {:error, {:duplicate_product_profile_ids, duplicates}}
    end
  end
end
