defmodule CatalystWeb.Auth.LegacyLogin do
  @moduledoc """
  Compatibility lookup for historical web login test hooks.

  Provider packs own the legacy environment-key metadata. Generic web code
  resolves it through the registered authentication descriptor.
  """

  alias Catalyst.Auth.Flow
  alias Catalyst.LLM.{ProviderConfig, Registry}

  @allowed_keys [:login_fun, :grok_login_fun]

  @doc "Return the historical configured login function for a credential provider."
  @spec configured(String.t()) :: function() | nil
  def configured(provider) when is_binary(provider) do
    provider
    |> legacy_key()
    |> then(&Application.get_env(:catalyst_web, &1))
  end

  def configured(_provider), do: nil

  defp legacy_key(provider) do
    with {:ok, flow} <- Flow.resolve(provider),
         %ProviderConfig{controls: controls} <-
           Enum.find(Map.values(Registry.list()), &(&1.auth == flow)),
         key when key in @allowed_keys <- Map.get(controls, :legacy_web_login_env) do
      key
    else
      _missing -> :login_fun
    end
  end
end
