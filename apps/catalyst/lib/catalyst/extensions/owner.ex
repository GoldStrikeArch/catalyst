defmodule Catalyst.Extensions.Owner do
  @moduledoc """
  Shared owner-id conventions for the runtime registries.

  Every owner-aware registry (tools, providers, prompts, workflows, context)
  tags registrations with an owner term. Host registrations pass no owner and
  normalize to `:host`; extension registrations carry the extension's owner id.
  This module is a plain shared helper on purpose — each registry keeps its own
  validation, storage shape, and error tuples (see architecture notes on
  registry autonomy).
  """

  @host :host

  @doc "The reserved owner id for host (non-extension) registrations."
  @spec host() :: :host
  def host, do: @host

  @doc "Normalize a registration's `:owner` option — `nil` means the host."
  @spec normalize(term()) :: term()
  def normalize(nil), do: @host
  def normalize(owner), do: owner
end
