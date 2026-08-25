defmodule Catalyst.Capabilities do
  @moduledoc """
  Resolves extension-defined run capabilities.

  A capability resolver receives the normalized run config and returns a
  boolean. Tools declare required capabilities in their metadata; the workflow
  support layer filters tools only after all runtime tool sources are resolved.
  """

  alias Catalyst.ExtensionAPI
  alias Catalyst.Runtime.Registry

  @doc "Return every capability granted for this run."
  @spec granted(map()) :: [atom()]
  def granted(config) when is_map(config) do
    :capability
    |> Registry.list()
    |> Enum.flat_map(fn %{key: name, value: resolver} ->
      case safely_granted?(resolver, config) do
        true -> [name]
        false -> []
      end
    end)
  end

  @doc false
  @spec register_extension_capability(ExtensionAPI.t(), atom(), (map() -> boolean())) ::
          :ok | {:error, term()}
  def register_extension_capability(%ExtensionAPI{owner: owner}, name, resolver)
      when is_atom(name) and is_function(resolver, 1) do
    Registry.put(:capability, name, resolver, owner: owner, collision_key: name)
  end

  def register_extension_capability(_api, name, resolver),
    do: {:error, {:invalid_capability, name, resolver}}

  defp safely_granted?(resolver, config) do
    resolver.(config) == true
  rescue
    _exception -> false
  catch
    _kind, _reason -> false
  end
end
