defmodule Catalyst.LLM.RegistryTest do
  # async: false — the provider registry is global mutable state, and one test
  # overrides a built-in.
  use ExUnit.Case, async: false

  alias Catalyst.Content
  alias Catalyst.LLM.{ProviderConfig, Registry}

  defmodule EchoProvider do
    @behaviour Catalyst.LLM.Provider

    @impl true
    def stream(model, _context, _opts, _sink) do
      {:ok,
       %Catalyst.Message.Assistant{
         content: Content.text("echo!"),
         model: model && model.id,
         stop_reason: :stop,
         timestamp: Catalyst.Message.now()
       }}
    end
  end

  test "kernel providers are available" do
    assert {:ok, Catalyst.LLM.Faux} = Registry.fetch("faux")
    assert {:ok, Catalyst.LLM.OpenAICodex.Provider} = Registry.fetch("openai-codex-responses")

    assert Map.has_key?(Registry.list(), "faux")
  end

  test "register / fetch / list / unregister a provider at runtime" do
    on_exit(fn -> Registry.unregister_provider("echo") end)

    assert :ok = Registry.register_provider("echo", EchoProvider)
    assert {:ok, EchoProvider} = Registry.fetch("echo")
    assert {:ok, %ProviderConfig{module: EchoProvider}} = Registry.fetch_config("echo")
    assert Map.has_key?(Registry.list(), "echo")

    Registry.unregister_provider("echo")
    assert {:error, {:unknown_api, "echo"}} = Registry.fetch("echo")
  end

  test "unregister_owner removes only that owner's providers" do
    on_exit(fn ->
      Catalyst.Runtime.Registry.purge_owner("ownerA")
      Registry.unregister_provider("p1")
    end)

    Registry.register_provider("p1", EchoProvider, owner: "ownerA")
    assert {:ok, EchoProvider} = Registry.fetch("p1")

    Catalyst.Runtime.Registry.purge_owner("ownerA")
    assert {:error, _} = Registry.fetch("p1")
  end

  test "overriding then unregistering restores the built-in" do
    on_exit(fn -> Registry.unregister_provider("faux") end)

    Registry.register_provider("faux", EchoProvider)
    assert {:ok, EchoProvider} = Registry.fetch("faux")

    Registry.unregister_provider("faux")
    assert {:ok, Catalyst.LLM.Faux} = Registry.fetch("faux")
  end

  test "a bare implementation override preserves existing provider controls" do
    api = "openai-codex-responses"
    on_exit(fn -> Registry.unregister_provider(api) end)

    assert :ok = Registry.register_provider(api, EchoProvider)

    assert {:ok,
            %ProviderConfig{
              module: EchoProvider,
              controls: Catalyst.LLM.OpenAICodex.Controls
            }} = Registry.fetch_config(api)
  end

  test "extension owners cannot replace each other's provider and purge is owner-safe" do
    on_exit(fn ->
      Catalyst.Runtime.Registry.purge_owner("provider_owner_a")
      Catalyst.Runtime.Registry.purge_owner("provider_owner_b")
      Registry.unregister_provider("faux")
    end)

    assert :ok = Registry.register_provider("faux", EchoProvider, owner: "provider_owner_a")

    assert {:error, {:owner_collision, :provider, "faux", "provider_owner_a", "provider_owner_b"}} =
             Registry.register_provider("faux", Catalyst.LLM.Demo, owner: "provider_owner_b")

    assert {:ok, EchoProvider} = Registry.fetch("faux")

    :ok = Catalyst.Runtime.Registry.purge_owner("provider_owner_b")
    assert {:ok, EchoProvider} = Registry.fetch("faux")

    :ok = Catalyst.Runtime.Registry.purge_owner("provider_owner_a")
    assert {:ok, Catalyst.LLM.Faux} = Registry.fetch("faux")
  end

  test "an ownerless host registration cannot detach an extension-owned provider" do
    on_exit(fn -> Registry.unregister_provider("owned-api") end)

    assert :ok =
             Registry.register_provider("owned-api", EchoProvider, owner: "provider_extension")

    assert {:error, {:owner_collision, :provider, "owned-api", "provider_extension", :host}} =
             Registry.register_provider("owned-api", Catalyst.LLM.Demo)

    assert {:ok, EchoProvider} = Registry.fetch("owned-api")
    assert :ok = Catalyst.Runtime.Registry.purge_owner("provider_extension")
    assert {:error, {:unknown_api, "owned-api"}} = Registry.fetch("owned-api")
  end

  test "registration validates provider exports stream/4" do
    defmodule InvalidProvider do
      def other, do: :ok
    end

    # Remove a prior runtime value so validation is the only failure under test.
    Registry.unregister_provider("invalid")

    assert {:error, {:missing_stream_4, InvalidProvider}} =
             Registry.register_provider("invalid", InvalidProvider)
  end
end
