defmodule Catalyst.LLM.GrokSubscription do
  @moduledoc """
  Model catalog and `%Catalyst.Model{}` construction for direct SuperGrok
  subscription access through xAI's Grok Build proxy.
  """

  alias Catalyst.Model

  @base_url "https://cli-chat-proxy.grok.com/v1"
  @default_model "grok-4.6"
  @default_effort "high"
  @efforts ~w(low medium high xhigh)
  @models [
    %{
      id: "grok-4.6",
      name: "Grok 4.6",
      provider: "grok-subscription",
      efforts: @efforts,
      default_effort: @default_effort,
      fast?: false,
      context_window: 500_000,
      max_context_window: 500_000,
      effective_context_window_percent: 95,
      auto_compact_token_limit: nil
    }
  ]

  @typedoc "One Grok model picker entry."
  @type catalog_entry :: %{
          id: String.t(),
          name: String.t(),
          provider: String.t(),
          efforts: [String.t()],
          default_effort: String.t(),
          fast?: boolean(),
          context_window: pos_integer(),
          max_context_window: pos_integer(),
          effective_context_window_percent: pos_integer(),
          auto_compact_token_limit: nil
        }

  @doc "Models available through the SuperGrok subscription transport."
  @spec list_models() :: [catalog_entry()]
  def list_models, do: @models

  @doc "Catalog entry for `id`, falling back to a renderable custom entry."
  @spec catalog_entry(String.t()) :: catalog_entry()
  def catalog_entry(id) do
    Enum.find(@models, &(&1.id == id)) ||
      %{
        hd(@models)
        | id: id,
          name: id,
          context_window: 500_000,
          max_context_window: 500_000
      }
  end

  @doc "Build a Grok subscription model."
  @spec model(String.t(), keyword()) :: Model.t()
  def model(id \\ default_model_id(), opts \\ []) do
    entry = catalog_entry(id)
    explicit_window = Model.positive_int(Keyword.get(opts, :context_window))

    %Model{
      id: id,
      name: entry.name,
      api: "grok-subscription-chat-completions",
      provider: "grok-subscription",
      base_url: Keyword.get(opts, :base_url, @base_url),
      reasoning: true,
      input: [:text, :image],
      context_window: explicit_window || entry.context_window,
      max_context_window: entry.max_context_window,
      effective_context_window_percent: entry.effective_context_window_percent,
      auto_compact_token_limit: entry.auto_compact_token_limit,
      context_window_source: context_window_source(explicit_window),
      max_tokens: Keyword.get(opts, :max_tokens, 128_000)
    }
  end

  @doc "Default Grok model id."
  @spec default_model_id() :: String.t()
  def default_model_id, do: Application.get_env(:catalyst, :grok_model, @default_model)

  @doc "Default Grok reasoning effort."
  @spec default_effort() :: String.t()
  def default_effort, do: @default_effort

  defp context_window_source(window) when is_integer(window), do: :session
  defp context_window_source(_window), do: :catalog
end
