defmodule Catalyst.Auth.XAILogin do
  @moduledoc """
  Interactive device login for the optional SuperGrok provider.

  This lives with the provider feature so the kernel authentication store and
  web shell do not need to know xAI's protocol or provider id.
  """

  alias Catalyst.Auth.{TokenStore, XAIOAuth}

  @doc """
  Request a device code, open its verification URL, await approval, and persist
  the resulting credentials.
  """
  @spec login(keyword()) :: {:ok, String.t() | nil} | {:error, term()}
  def login(opts \\ []) do
    with {:ok, device} <- XAIOAuth.request_device_code(opts) do
      url = device.verification_uri_complete || device.verification_uri
      Catalyst.Auth.open_browser(url, opts)

      IO.puts("""
      Opening your browser to sign in to SuperGrok.
      If it doesn't open automatically, visit:

        #{device.verification_uri}

      and enter code: #{device.user_code}
      """)

      with {:ok, creds} <- XAIOAuth.await_device_code(device, opts),
           :ok <- TokenStore.put(XAIOAuth.provider_id(), creds) do
        {:ok, creds["account_id"]}
      end
    end
  end
end
