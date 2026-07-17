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

  alias Catalyst.LLM.OpenAICodex.{Catalog, CatalogCache}
  alias Catalyst.Model

  @base_url "https://chatgpt.com/backend-api"

  @typedoc "One catalog entry (UI metadata, not the request `%Model{}`)."
  @type catalog_entry :: Catalog.entry()

  @typedoc "One consistent catalog read plus the selected model entry."
  @type catalog_snapshot :: %{models: [catalog_entry()], selected: catalog_entry()}

  @doc """
  The Codex model catalog: `config :catalyst, :codex_models` override wins,
  else the live list fetched from `GET <base>/codex/models` (refreshed in the
  background when authenticated — see `refresh_live_models/0`), else the
  built-in list. The configured default model id is always present (appended
  as a bare entry when it isn't in the catalog, so a custom `:codex_model`
  still shows up in pickers).
  """
  @spec list_models() :: [catalog_entry()]
  def list_models do
    entries =
      cond do
        configured = Application.get_env(:catalyst, :codex_models) ->
          Enum.map(configured, &Catalog.normalize/1)

        true ->
          live_or_built_in()
      end

    case Enum.any?(entries, &(&1.id == default_model_id())) do
      true -> entries
      false -> entries ++ [Catalog.normalize(%{id: default_model_id()})]
    end
  end

  @doc """
  Fetch the live catalog now (requires ChatGPT auth) and cache it for
  `list_models/0`. Returns `{:ok, entries}` or `{:error, reason}`.
  """
  @spec refresh_live_models() :: {:ok, [catalog_entry()]} | {:error, term()}
  defdelegate refresh_live_models(), to: CatalogCache, as: :refresh

  @doc """
  Fold an `x-models-etag` observed on a /responses response (SSE headers or
  the ws upgrade — the Codex CLI's refresh signal): an etag matching the
  cached catalog just renews its TTL (no network); a NEW etag means the
  server-side catalog changed, so a background refetch is kicked. No-op when
  live models are disabled.
  """
  @spec notice_models_etag(String.t() | nil) :: :ok
  defdelegate notice_models_etag(etag), to: CatalogCache, as: :notice_etag

  @doc """
  GET `<base>/codex/models?client_version=…` and parse the catalog: `list`-
  visible models sorted by `priority`, with Fast support read from
  `service_tiers`/`additional_speed_tiers` and efforts from
  `supported_reasoning_levels`. Returns the response `ETag` too — later
  `x-models-etag` observations on /responses compare against it.
  (Schema per codex-rs `protocol/openai_models.rs`.)
  """
  @spec fetch_live_models(String.t(), String.t(), String.t()) ::
          {:ok, [catalog_entry()], String.t() | nil} | {:error, term()}
  defdelegate fetch_live_models(token, account_id, base_url), to: CatalogCache

  @doc false
  @spec parse_live_models([map()]) :: [catalog_entry()]
  defdelegate parse_live_models(models), to: Catalog

  @doc "Catalog entry for `id` (a normalized bare entry when unknown, so callers always render)."
  @spec catalog_entry(String.t()) :: catalog_entry()
  def catalog_entry(id) do
    id |> catalog_snapshot() |> Map.fetch!(:selected)
  end

  @doc "Read the catalog once and resolve `id` from that same consistent snapshot."
  @spec catalog_snapshot(String.t()) :: catalog_snapshot()
  def catalog_snapshot(id) do
    models = list_models()
    selected = Enum.find(models, &(&1.id == id)) || Catalog.normalize(%{id: id})
    %{models: models, selected: selected}
  end

  @doc "Supported reasoning efforts, lowest to highest."
  @spec efforts() :: [String.t()]
  defdelegate efforts(), to: Catalog

  @doc "The server-side default reasoning effort."
  @spec default_effort() :: String.t()
  defdelegate default_effort(), to: Catalog

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
      # The gpt-5.x Codex models are vision-capable (live catalog
      # `input_modalities` defaults to ["text","image"]; PI declares the same).
      input: [:text, :image],
      context_window: Keyword.get(opts, :context_window, 272_000),
      max_tokens: Keyword.get(opts, :max_tokens, 128_000)
    }
  end

  @doc "The configured default Codex model id (`config :catalyst, :codex_model`)."
  @spec default_model_id() :: String.t()
  def default_model_id, do: Application.get_env(:catalyst, :codex_model, "gpt-5.4")

  defp live_or_built_in do
    case CatalogCache.models() do
      [] -> Catalog.built_in()
      entries -> entries
    end
  end
end
