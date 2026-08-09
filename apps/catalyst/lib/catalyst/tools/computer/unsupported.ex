defmodule Catalyst.Tools.Computer.Unsupported do
  @moduledoc """
  The no-op computer-use backend for non-Darwin hosts (plan §3). Every
  `Catalyst.Tools.Computer.Backend` callback returns
  `{:error, :unsupported_platform}`, so the capability is never granted and the
  `/computer` page can explain why rather than presenting a "tool exists but
  always errors" state.
  """

  @behaviour Catalyst.Tools.Computer.Backend

  @impl true
  def screens, do: {:error, :unsupported_platform}

  @impl true
  def windows, do: {:error, :unsupported_platform}

  @impl true
  def cursor, do: {:error, :unsupported_platform}

  @impl true
  def input(_op), do: {:error, :unsupported_platform}

  @impl true
  def capture(_request), do: {:error, :unsupported_platform}

  @impl true
  def grants, do: {:error, :unsupported_platform}

  @impl true
  def capture_grant, do: {:error, :unsupported_platform}
end
