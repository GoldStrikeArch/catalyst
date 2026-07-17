defmodule Catalyst.LLM.OpenAICodex do
  @moduledoc """
  Helpers for the OpenAI Codex (ChatGPT subscription) provider. `model/2` builds
  a `Catalyst.Model` for a Codex model id. The default id is configurable with
  `config :catalyst, :codex_model` — set it to whatever your subscription serves.
  """

  alias Catalyst.Model

  @base_url "https://chatgpt.com/backend-api"

  @doc "Build a Codex `%Model{}` for `id` (defaults to the configured codex_model)."
  @spec model(String.t(), keyword()) :: Model.t()
  def model(id \\ default_model_id(), opts \\ []) do
    %Model{
      id: id,
      name: id,
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
end
