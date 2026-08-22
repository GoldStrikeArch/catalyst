defmodule Catalyst.Product.Selection do
  @moduledoc """
  Durable selection of a known compiled product profile.

  The file stores a stable profile id, never an atom or module name. Resolution
  maps that id through the host's configured profile allow-list and falls back
  to the default coding-agent profile when the file is absent or invalid.
  """

  alias Catalyst.Files.AtomicWrite

  @doc "Return the selected profile module and the source of that decision."
  @spec active() :: %{id: String.t(), module: module(), source: :persisted | :default | :fallback}
  def active do
    case read_id() do
      {:ok, id} -> selected(id)
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
    configured = Application.get_env(:catalyst, :product_profiles, %{})
    Map.merge(%{Catalyst.Product.Default.id() => Catalyst.Product.Default}, configured)
  end

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

  defp selected(id) do
    case fetch(id) do
      {:ok, profile} -> %{id: id, module: profile, source: :persisted}
      {:error, _reason} -> default(:fallback)
    end
  end

  defp default(source) do
    %{id: Catalyst.Product.Default.id(), module: Catalyst.Product.Default, source: source}
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
    callbacks = [id: 0, tools: 0]

    case Code.ensure_loaded?(profile) and
           Enum.all?(callbacks, fn {name, arity} -> function_exported?(profile, name, arity) end) and
           profile.id() == id do
      true -> {:ok, profile}
      false -> {:error, {:unknown_product_profile, id}}
    end
  rescue
    _error -> {:error, {:unknown_product_profile, id}}
  catch
    _kind, _reason -> {:error, {:unknown_product_profile, id}}
  end

  defp validate_profile(id, _profile), do: {:error, {:unknown_product_profile, id}}
end
