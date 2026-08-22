defmodule Catalyst.Auth.Flow do
  @moduledoc """
  Authentication lifecycle owned by an LLM provider descriptor.

  Flow modules keep login and credential refresh provider-specific while the
  shell and token store dispatch only by the credential provider id.
  """

  alias Catalyst.LLM.Registry
  alias Catalyst.Tasks

  @default_metadata_timeout 1_000

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
    matches = Enum.filter(descriptors(), &(&1.provider_id == provider_id))

    case matches do
      [%{flow: flow}] -> {:ok, flow}
      [] -> {:error, {:unknown_auth_provider, provider_id}}
      _many -> {:error, {:ambiguous_auth_provider, provider_id}}
    end
  end

  @doc "Return a registered flow's bounded, validated human-facing label."
  @spec label(String.t()) ::
          {:ok, String.t()}
          | {:error,
             {:unknown_auth_provider, String.t()} | {:ambiguous_auth_provider, String.t()}}
  def label(provider_id) when is_binary(provider_id) do
    matches = Enum.filter(descriptors(), &(&1.provider_id == provider_id))

    case matches do
      [%{label: label}] -> {:ok, label}
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

  defp descriptors do
    Registry.list()
    |> Map.values()
    |> Enum.map(& &1.auth)
    |> Enum.filter(&flow?/1)
    |> Enum.uniq()
    |> Enum.flat_map(&descriptor/1)
  end

  defp descriptor(flow) do
    task = Tasks.async(fn -> {flow.provider_id(), flow.label()} end)

    case Tasks.await(task, metadata_timeout()) do
      {:ok, {provider_id, label}}
      when is_binary(provider_id) and provider_id != "" and is_binary(label) and label != "" ->
        [%{flow: flow, provider_id: provider_id, label: label}]

      _invalid_or_unavailable ->
        []
    end
  end

  defp metadata_timeout do
    case Application.get_env(:catalyst, :auth_flow_metadata_timeout, @default_metadata_timeout) do
      timeout when is_integer(timeout) and timeout >= 0 -> timeout
      _invalid -> @default_metadata_timeout
    end
  end
end
