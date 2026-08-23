defmodule CatalystWeb.Auth.Login do
  @moduledoc """
  Resolves the host-owned authentication callback for one provider.

  Tests and embedded hosts may inject `:auth_login_fun`; production delegates to
  the provider descriptor through `Catalyst.Auth`.
  """

  @doc "Return a zero-arity login function for the selected provider."
  @spec callback(String.t()) :: (-> term())
  def callback(provider) when is_binary(provider) do
    case configured_override(provider) do
      fun when is_function(fun, 1) -> fn -> fun.(provider) end
      fun when is_function(fun, 0) -> fun
      nil -> fn -> Catalyst.Auth.login(provider) end
    end
  end

  defp configured_override(provider) do
    Application.get_env(:catalyst_web, :auth_login_fun) ||
      CatalystWeb.Auth.LegacyLogin.configured(provider)
  end
end
