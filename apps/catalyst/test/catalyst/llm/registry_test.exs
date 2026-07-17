defmodule Catalyst.LLM.RegistryTest do
  # async: false — the provider registry is global mutable state, and one test
  # overrides a built-in.
  use ExUnit.Case, async: false

  alias Catalyst.{Content, Model}
  alias Catalyst.LLM.{ProviderConfig, Registry}
  alias Catalyst.Session.{Manager, Server}

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

  test "built-in providers are seeded" do
    assert {:ok, Catalyst.LLM.Faux} = Registry.fetch("faux")
    assert {:ok, Catalyst.LLM.OpenAICodex.Provider} = Registry.fetch("openai-codex-responses")
    assert Map.has_key?(Registry.list(), "faux")
  end

  test "register / fetch / list / unregister a provider at runtime" do
    on_exit(fn -> Registry.unregister_provider("echo") end)

    assert :ok = Registry.register_provider("echo", EchoProvider)
    assert {:ok, EchoProvider} = Registry.fetch("echo")
    assert %ProviderConfig{module: EchoProvider} = Registry.fetch_config("echo")
    assert Map.has_key?(Registry.list(), "echo")

    Registry.unregister_provider("echo")
    assert {:error, {:unknown_api, "echo"}} = Registry.fetch("echo")
  end

  test "unregister_owner removes only that owner's providers" do
    on_exit(fn ->
      Registry.unregister_owner("ownerA")
      Registry.unregister_provider("p1")
    end)

    Registry.register_provider("p1", EchoProvider, owner: "ownerA")
    assert {:ok, EchoProvider} = Registry.fetch("p1")

    Registry.unregister_owner("ownerA")
    assert {:error, _} = Registry.fetch("p1")
  end

  test "overriding then unregistering restores the built-in" do
    on_exit(fn -> Registry.unregister_provider("faux") end)

    Registry.register_provider("faux", EchoProvider)
    assert {:ok, EchoProvider} = Registry.fetch("faux")

    Registry.unregister_provider("faux")
    assert {:ok, Catalyst.LLM.Faux} = Registry.fetch("faux")
  end

  test "a session resolves its provider by api name from the registry" do
    Registry.register_provider("echo", EchoProvider)

    model = %Model{id: "echo-1", api: "echo"}

    {:ok, %{id: id, pid: pid}} =
      Manager.start_session(cwd: System.tmp_dir!(), provider: "echo", model: model)

    on_exit(fn ->
      Manager.stop(id)
      Registry.unregister_provider("echo")
    end)

    Phoenix.PubSub.subscribe(Catalyst.PubSub, Server.topic(id))
    Server.prompt(pid, "hi")

    assert_receive {:agent_event, %Catalyst.Agent.Event.AgentEnd{}}, 2_000

    last = Server.state(pid).messages |> List.last()
    assert Content.text_of(last.content) == "echo!"
  end
end
