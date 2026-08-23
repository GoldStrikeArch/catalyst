defmodule CatalystWeb.CodexControlsTest do
  # async: false — stubs the login fun and writes the shared codex prefs.
  use CatalystWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Catalyst.LLM.OpenAICodex
  alias Catalyst.LLM.OpenAICodex.CatalogCache
  alias Catalyst.LLM.Registry
  alias Catalyst.Session.{Manager, Server}

  @codex_api "openai-codex-responses"
  @capture_pid_env :model_request_capture_pid
  @codex_prefs_ptr {CatalystWeb.ShellLive, :codex_prefs}

  defmodule RequestCaptureProvider do
    @moduledoc false
    @behaviour Catalyst.LLM.Provider

    alias Catalyst.{Content, Message, Usage}
    alias Catalyst.LLM.OpenAICodex.Request

    @capture_pid_env :model_request_capture_pid

    @impl true
    def stream(model, context, opts, _sink) do
      body = Request.build(model, context, opts)
      send(Application.fetch_env!(:catalyst_web, @capture_pid_env), {:codex_request, body})

      assistant = %Message.Assistant{
        content: [%Content.Text{text: "captured"}],
        api: model.api,
        provider: model.provider,
        model: model.id,
        usage: %Usage{},
        stop_reason: :stop,
        timestamp: Message.now()
      }

      {:ok, assistant}
    end
  end

  defmodule ThirdProvider do
    @behaviour Catalyst.LLM.Provider

    @impl true
    def stream(_model, _context, _opts, _sink), do: {:error, :unused}
  end

  defmodule ThirdCatalog do
    @behaviour Catalyst.LLM.ModelCatalog

    @entry %{
      id: "third-model",
      name: "Third Model",
      efforts: ["medium"],
      default_effort: "medium",
      fast?: false
    }

    @impl true
    def default_model_id, do: @entry.id

    @impl true
    def catalog_snapshot(_id), do: %{models: [@entry], selected: @entry}

    @impl true
    def model(id), do: %Catalyst.Model{id: id, api: "third-api", provider: "third"}
  end

  defmodule ThirdAuth do
    @behaviour Catalyst.Auth.Flow

    @impl true
    def provider_id, do: "third-auth"

    @impl true
    def label, do: "Third Account"

    @impl true
    def login(_opts) do
      send(Application.fetch_env!(:catalyst_web, :third_auth_test_pid), :third_login_called)
      {:ok, "third-user"}
    end

    @impl true
    def refresh(credentials), do: {:ok, credentials}
  end

  setup do
    previous_models = CatalogCache.models()
    previous_prefs = :persistent_term.get(@codex_prefs_ptr, :not_set)
    :ok = CatalogCache.reset()

    on_exit(fn ->
      restore_prefs(previous_prefs)
      restore_catalog(previous_models)
    end)

    :ok
  end

  defp session_pid(view) do
    {:ok, pid} = Manager.whereis(session_id(view))
    pid
  end

  defp restore_prefs(:not_set), do: :persistent_term.erase(@codex_prefs_ptr)
  defp restore_prefs(prefs), do: :persistent_term.put(@codex_prefs_ptr, prefs)

  defp restore_catalog([]), do: CatalogCache.reset()

  defp restore_catalog(models) do
    :ok = CatalogCache.reset()
    CatalogCache.store(models)
  end

  defp model_option_values(view) do
    view
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("#codex-opts select[name='model'] option")
    |> LazyHTML.attribute("value")
  end

  test "the run controls reconfigure the live session in place", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/legacy-chat")
    assert has_element?(view, "#codex-opts")
    assert has_element?(view, "#codex-opts option[value='gpt-5.6-sol']")
    assert has_element?(view, "#codex-opts option[value='gpt-5.6-terra']")
    assert has_element?(view, "#codex-opts option[value='gpt-5.6-luna']")
    pid = session_pid(view)

    # The codex session starts with the default settings already applied.
    snap = Server.state(pid)
    assert snap.model.id == OpenAICodex.default_model_id()
    assert snap.opts[:reasoning_effort] == "medium"
    assert snap.opts[:transport] == "auto"
    refute snap.opts[:service_tier]

    view
    |> form("#codex-opts")
    |> render_change(%{
      "model" => "gpt-5.6-sol",
      "effort" => "ultra",
      "transport" => "websocket"
    })

    snap = Server.state(pid)
    assert snap.model.id == "gpt-5.6-sol"
    assert snap.opts[:reasoning_effort] == "ultra"
    assert snap.opts[:transport] == "websocket"

    # Fast → service_tier "priority"; toggling off DELETES the key.
    view |> element("#codex-fast-toggle") |> render_click()
    assert Server.state(pid).opts[:service_tier] == "priority"

    view |> element("#codex-fast-toggle") |> render_click()
    refute Keyword.has_key?(Server.state(pid).opts, :service_tier)

    # Reconfigured in place: same session process, transcript untouched.
    assert session_pid(view) == pid
  end

  test "Fast remains available for every GPT-5.6 model omitted by the live catalog", %{
    conn: conn
  } do
    live =
      OpenAICodex.parse_live_models([
        %{"slug" => "gpt-5.5", "visibility" => "list", "priority" => 0},
        %{"slug" => "gpt-5.4", "visibility" => "list", "priority" => 1}
      ])

    :ok = CatalogCache.store(live)
    {:ok, view, _html} = live(conn, "/legacy-chat")
    pid = session_pid(view)

    Enum.each(~w(gpt-5.6-sol gpt-5.6-terra gpt-5.6-luna), fn model_id ->
      view |> form("#codex-opts") |> render_change(%{"model" => model_id})

      assert has_element?(view, "#codex-fast-toggle")
      view |> element("#codex-fast-toggle") |> render_click()
      assert Server.state(pid).opts[:service_tier] == "priority"

      view |> element("#codex-fast-toggle") |> render_click()
      refute Keyword.has_key?(Server.state(pid).opts, :service_tier)
    end)
  end

  test "fast is clamped off when switching to a model without the priority tier", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/legacy-chat")
    pid = session_pid(view)

    view |> element("#codex-fast-toggle") |> render_click()
    assert Server.state(pid).opts[:service_tier] == "priority"

    view |> form("#codex-opts") |> render_change(%{"model" => "gpt-5.4-mini"})

    refute Keyword.has_key?(Server.state(pid).opts, :service_tier)
    refute has_element?(view, "#codex-fast-toggle")
  end

  test "Grok 4.6 selects the direct subscription provider and SuperGrok auth", %{conn: conn} do
    parent = self()

    Application.put_env(:catalyst_web, :auth_login_fun, fn provider ->
      assert provider == Catalyst.Auth.XAIOAuth.provider_id()
      send(parent, :grok_login_called)
      {:ok, "xai-user"}
    end)

    on_exit(fn -> Application.delete_env(:catalyst_web, :auth_login_fun) end)

    {:ok, view, _html} = live(conn, "/legacy-chat")
    pid = session_pid(view)

    assert has_element?(view, "#codex-opts option[value='grok-4.6']", "Grok 4.6")

    view
    |> form("#codex-opts")
    |> render_change(%{"model" => "grok-4.6", "effort" => "xhigh"})

    snapshot = Server.state(pid)
    assert snapshot.model.id == "grok-4.6"
    assert snapshot.model.api == "grok-subscription-chat-completions"
    assert snapshot.model.provider == "grok-subscription"
    assert snapshot.model.context_window == 500_000
    assert snapshot.opts[:reasoning_effort] == "xhigh"
    refute Keyword.has_key?(snapshot.opts, :service_tier)
    refute Keyword.has_key?(snapshot.opts, :transport)
    refute has_element?(view, "#codex-fast-toggle")
    assert has_element?(view, "#login-button", "Sign in to SuperGrok")

    view |> element("#login-button") |> render_click()
    assert_receive :grok_login_called, 1_000
    assert has_element?(view, ~s(#logout-button[title="Sign out of SuperGrok"]))
  end

  test "a third provider's descriptor supplies Shell login without a provider branch", %{
    conn: conn
  } do
    Application.put_env(:catalyst_web, :third_auth_test_pid, self())

    config = %Catalyst.LLM.ProviderConfig{
      id: "third",
      module: ThirdProvider,
      name: "Third Account",
      catalog: ThirdCatalog,
      auth: ThirdAuth
    }

    assert :ok = Registry.register_provider("third-api", config)

    on_exit(fn ->
      Application.delete_env(:catalyst_web, :third_auth_test_pid)
      Registry.unregister_provider("third-api")
    end)

    {:ok, view, _html} = live(conn, "/legacy-chat")
    assert has_element?(view, "#codex-opts option[value='third-model']", "Third Model")

    view |> form("#codex-opts") |> render_change(%{"model" => "third-model"})
    assert has_element?(view, "#login-button", "Sign in to Third Account")

    view |> element("#login-button") |> render_click()
    assert_receive :third_login_called
    assert has_element?(view, ~s(#logout-button[title="Sign out of Third Account"]))
  end

  test "a Luna selection reaches the provider request for a newly created chat", %{conn: conn} do
    {:ok, previous_provider} = Registry.fetch_config(@codex_api)
    Application.put_env(:catalyst_web, @capture_pid_env, self())
    :ok = Registry.register_provider(@codex_api, RequestCaptureProvider)

    on_exit(fn ->
      Application.delete_env(:catalyst_web, @capture_pid_env)
      Registry.register_provider(@codex_api, previous_provider)
    end)

    {:ok, view, _html} = live(conn, "/legacy-chat")
    view |> element("#new-session-button") |> render_click()

    view
    |> form("#codex-opts")
    |> render_change(%{"model" => "gpt-5.6-luna"})

    assert Server.state(session_pid(view)).model.id == "gpt-5.6-luna"

    submit_prompt(view, "What is your model name?")
    assert_receive {:codex_request, body}

    assert body["model"] == "gpt-5.6-luna"
    assert body["instructions"] =~ ~s(exact model identifier "gpt-5.6-luna")
    refute body["instructions"] =~ "gpt-5.4"
  end

  test "New preserves the selected model and ordered picker after a live catalog refresh", %{
    conn: conn
  } do
    :ok = CatalogCache.reset()
    {:ok, view, _html} = live(conn, "/legacy-chat")

    assert Enum.take(model_option_values(view), 5) ==
             ~w(gpt-5.6-sol gpt-5.6-terra gpt-5.6-luna gpt-5.5 gpt-5.4)

    view
    |> form("#codex-opts")
    |> render_change(%{
      "model" => "gpt-5.6-luna",
      "effort" => "max",
      "transport" => "sse"
    })

    view |> element("#codex-fast-toggle") |> render_click()
    previous_pid = session_pid(view)

    live =
      OpenAICodex.parse_live_models([
        %{
          "slug" => "gpt-5.5",
          "display_name" => "GPT-5.5",
          "visibility" => "list",
          "priority" => 0
        },
        %{
          "slug" => "gpt-5.4",
          "display_name" => "GPT-5.4",
          "visibility" => "list",
          "priority" => 1
        },
        %{
          "slug" => "gpt-5.4-mini",
          "display_name" => "GPT-5.4 mini",
          "visibility" => "list",
          "priority" => 2
        },
        %{
          "slug" => "gpt-5.3-codex-spark",
          "display_name" => "GPT-5.3 Codex Spark",
          "visibility" => "list",
          "priority" => 3
        }
      ])

    :ok = CatalogCache.store(live)
    view |> element("#new-session-button") |> render_click()

    refute session_pid(view) == previous_pid
    snapshot = Server.state(session_pid(view))
    assert snapshot.model.id == "gpt-5.6-luna"
    assert snapshot.opts[:reasoning_effort] == "max"
    assert snapshot.opts[:service_tier] == "priority"
    assert snapshot.opts[:transport] == "sse"

    assert Enum.take(model_option_values(view), 5) ==
             ~w(gpt-5.6-sol gpt-5.6-terra gpt-5.6-luna gpt-5.5 gpt-5.4)

    assert has_element?(
             view,
             "#codex-opts select[name='model'] option[value='gpt-5.6-luna'][selected]",
             "GPT-5.6-Luna"
           )

    assert has_element?(
             view,
             "#codex-opts select[name='effort'] option[value='max'][selected]"
           )

    assert has_element?(
             view,
             "#codex-opts select[name='transport'] option[value='sse'][selected]"
           )

    assert has_element?(view, "#codex-opts option[value='gpt-5.5']", "GPT-5.5")
    assert has_element?(view, "#codex-opts option[value='gpt-5.4']", "GPT-5.4")
  end
end
