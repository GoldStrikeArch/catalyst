defmodule Catalyst.Auth.Flow do
  @moduledoc """
  Authentication lifecycle owned by an LLM provider descriptor.

  Flow modules keep login and credential refresh provider-specific while the
  shell and token store dispatch only by the credential provider id.
  """

  alias Catalyst.LLM.Registry

  @typedoc "Validated credentials stored by `Catalyst.Auth.TokenStore`."
  @type credentials :: %{required(String.t()) => term()}

  @doc "Credential provider id used as the token-store key."
  @callback provider_id() :: String.t()

  @doc "Human-facing subscription or authentication name."
  @callback label() :: String.t()

  @doc "Run the provider's interactive login flow and persist its credentials."
  @callback login(keyword()) :: {:ok, String.t() | nil} | {:error, term()}

  @doc "Refresh stored credentials without exposing secrets in an error value."
  @callback refresh(credentials()) :: {:ok, credentials()} | {:error, term()}

  @doc "Resolve a registered flow by its credential provider id."
  @spec resolve(String.t()) ::
          {:ok, module()}
          | {:error,
             {:unknown_auth_provider, String.t()} | {:ambiguous_auth_provider, String.t()}}
  def resolve(provider_id) when is_binary(provider_id) do
    matches =
      Registry.list()
      |> Map.values()
      |> Enum.map(& &1.auth)
      |> Enum.filter(&flow?/1)
      |> Enum.uniq()
      |> Enum.filter(&(&1.provider_id() == provider_id))

    case matches do
      [flow] -> {:ok, flow}
      [] -> {:error, {:unknown_auth_provider, provider_id}}
      _many -> {:error, {:ambiguous_auth_provider, provider_id}}
    end
  end

  @doc false
  @spec flow?(term()) :: boolean()
  def flow?(flow) when is_atom(flow) and not is_nil(flow) do
    callbacks = [provider_id: 0, label: 0, login: 1, refresh: 1]

    Code.ensure_loaded?(flow) and
      Enum.all?(callbacks, &function_exported?(flow, elem(&1, 0), elem(&1, 1)))
  end

  def flow?(_flow), do: false
end
