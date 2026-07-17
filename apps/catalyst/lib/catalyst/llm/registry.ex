defmodule Catalyst.LLM.Registry do
  @moduledoc """
  Maps a model's `api` string to its provider module. Built to grow toward PI's
  provider breadth; P1 ships the `faux` test provider, P2 adds `openai-codex`.
  """

  @builtin %{
    "faux" => Catalyst.LLM.Faux,
    "openai-codex-responses" => Catalyst.LLM.OpenAICodex.Provider
  }

  @doc "Resolve the provider module for an api string. Config can override/extend."
  def fetch(api) when is_binary(api) do
    overrides = Application.get_env(:catalyst, :llm_providers, %{})

    case Map.get(overrides, api) || Map.get(@builtin, api) do
      nil -> {:error, {:unknown_api, api}}
      module -> {:ok, module}
    end
  end

  def fetch!(api) do
    case fetch(api) do
      {:ok, module} -> module
      {:error, reason} -> raise ArgumentError, "no LLM provider for api #{inspect(api)}: #{inspect(reason)}"
    end
  end
end
