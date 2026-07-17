defmodule Catalyst.LLM.OpenAICodex do
  @moduledoc """
  Helpers for the OpenAI Codex (ChatGPT subscription) provider: the model
  catalog and `%Catalyst.Model{}` construction.

  The catalog mirrors the Codex CLI's bundled model list (the CLI fetches the
  live list from `GET <base>/codex/models`; the entries here are its shipped
  fallback). Override it with `config :catalyst, :codex_models, [%{...}]` if
  your subscription serves different ids, and the default id with
  `config :catalyst, :codex_model`.

  Per-model capabilities the UI keys off:

    * `:efforts` — supported reasoning efforts (request `reasoning.effort`);
    * `:fast?` — whether the model supports the `priority` service tier
      ("Fast" in the ChatGPT UI: ~1.5x speed, increased usage), sent as
      `service_tier: "priority"`.
  """

  alias Catalyst.Model

  @base_url "https://chatgpt.com/backend-api"

  @efforts ~w(low medium high xhigh)
  @default_effort "medium"

  # Mirrors codex-rs/models-manager/models.json (visibility: list) as of
  # 2026-06: slug, display name, priority-tier ("Fast") support. All share a
  # 272k context window and low/medium/high/xhigh efforts (default medium).
  @models [
    %{id: "gpt-5.5", name: "GPT-5.5", fast?: true},
    %{id: "gpt-5.4", name: "GPT-5.4", fast?: true},
    %{id: "gpt-5.4-mini", name: "GPT-5.4 mini", fast?: false},
    %{id: "gpt-5.3-codex", name: "GPT-5.3 Codex", fast?: false},
    %{id: "gpt-5.2", name: "GPT-5.2", fast?: false}
  ]

  @typedoc "One catalog entry (UI metadata, not the request `%Model{}`)."
  @type catalog_entry :: %{
          id: String.t(),
          name: String.t(),
          fast?: boolean(),
          efforts: [String.t()],
          default_effort: String.t()
        }

  @doc """
  The Codex model catalog: `config :catalyst, :codex_models` override, else the
  built-in list. The configured default model id is always present (appended as
  a bare entry when it isn't in the catalog, so a custom `:codex_model` still
  shows up in pickers).
  """
  @spec list_models() :: [catalog_entry()]
  def list_models do
    configured = Application.get_env(:catalyst, :codex_models, @models)
    entries = Enum.map(configured, &normalize_entry/1)

    case Enum.any?(entries, &(&1.id == default_model_id())) do
      true -> entries
      false -> entries ++ [normalize_entry(%{id: default_model_id()})]
    end
  end

  @doc "Catalog entry for `id` (a normalized bare entry when unknown, so callers always render)."
  @spec catalog_entry(String.t()) :: catalog_entry()
  def catalog_entry(id) do
    Enum.find(list_models(), &(&1.id == id)) || normalize_entry(%{id: id})
  end

  @doc "Supported reasoning efforts, lowest to highest."
  @spec efforts() :: [String.t()]
  def efforts, do: @efforts

  @doc "The server-side default reasoning effort."
  @spec default_effort() :: String.t()
  def default_effort, do: @default_effort

  @doc "Build a Codex `%Model{}` for `id` (defaults to the configured codex_model)."
  @spec model(String.t(), keyword()) :: Model.t()
  def model(id \\ default_model_id(), opts \\ []) do
    %Model{
      id: id,
      name: catalog_entry(id).name,
      api: "openai-codex-responses",
      provider: "openai-codex",
      base_url: Keyword.get(opts, :base_url, @base_url),
      reasoning: true,
      input: [:text],
      context_window: Keyword.get(opts, :context_window, 272_000),
      max_tokens: Keyword.get(opts, :max_tokens, 128_000)
    }
  end

  @doc "The configured default Codex model id (`config :catalyst, :codex_model`)."
  @spec default_model_id() :: String.t()
  def default_model_id, do: Application.get_env(:catalyst, :codex_model, "gpt-5.4")

  defp normalize_entry(entry) do
    %{
      id: Map.fetch!(entry, :id),
      name: Map.get(entry, :name, Map.fetch!(entry, :id)),
      fast?: Map.get(entry, :fast?, false),
      efforts: Map.get(entry, :efforts, @efforts),
      default_effort: Map.get(entry, :default_effort, @default_effort)
    }
  end
end
