defmodule Catalyst.Session.RunContextEffectiveModelTest do
  use ExUnit.Case, async: false

  alias Catalyst.LLM.{ProviderConfig, Registry}
  alias Catalyst.Model
  alias Catalyst.Session.RunContext

  defmodule Provider do
    @behaviour Catalyst.LLM.Provider

    @impl true
    def stream(_model, _context, _opts, _sink), do: {:error, :unused}
  end

  defmodule Catalog do
    @behaviour Catalyst.LLM.ModelCatalog

    @entry %{
      id: "epoch-model",
      name: "Epoch Model",
      context_window: 77_777,
      max_context_window: 88_888,
      efforts: ["low"]
    }

    @impl true
    def default_model_id, do: @entry.id

    @impl true
    def catalog_snapshot(_id), do: %{models: [@entry], selected: @entry}

    @impl true
    def model(id), do: %Model{id: id, api: "epoch-api", provider: "epoch"}
  end

  test "nil and non-catalog models pass through unchanged" do
    assert RunContext.effective_model(nil) == nil

    model = %Model{id: "faux", api: "faux", context_window: 1_234}
    assert RunContext.effective_model(model) == model
  end

  test "a session-pinned codex model is not refreshed from the catalog" do
    model = %Model{
      id: "codex-mini",
      api: "openai-codex-responses",
      context_window: 4_242,
      context_window_source: :session
    }

    assert RunContext.effective_model(model) == model
  end

  test "a refreshable codex model gets concrete context metadata" do
    model = %Model{id: "unknown-codex-model", api: "openai-codex-responses"}
    resolved = RunContext.effective_model(model)

    assert %Model{api: "openai-codex-responses"} = resolved
    assert is_integer(resolved.context_window) and resolved.context_window > 0
    assert resolved.context_window_source in [:catalog, :persisted, :fallback]
  end

  test "a third provider refreshes metadata through its registered catalog" do
    on_exit(fn -> Registry.unregister_provider("epoch-api") end)

    assert :ok =
             Registry.register_provider(
               "epoch-api",
               %ProviderConfig{
                 id: "epoch",
                 module: Provider,
                 name: "Epoch",
                 catalog: Catalog
               }
             )

    resolved = RunContext.effective_model(%Model{id: "epoch-model", api: "epoch-api"})

    assert resolved.context_window == 77_777
    assert resolved.max_context_window == 88_888
    assert resolved.context_window_source == :catalog
  end
end
