defmodule Catalyst.LLM.OpenAICodexTest do
  # async: false — flips :codex_models / :codex_model app env.
  use ExUnit.Case, async: false

  alias Catalyst.LLM.OpenAICodex
  alias Catalyst.LLM.OpenAICodex.CatalogCache

  setup do
    Application.put_env(:catalyst, :codex_live_models, false)
    :ok = CatalogCache.reset()

    on_exit(fn ->
      Application.put_env(:catalyst, :codex_live_models, false)
      CatalogCache.reset()
    end)

    :ok
  end

  test "the built-in catalog lists the Codex models with efforts and Fast capability" do
    models = OpenAICodex.list_models()
    ids = Enum.map(models, & &1.id)

    assert "gpt-5.4" in ids
    assert "gpt-5.5" in ids

    gpt54 = Enum.find(models, &(&1.id == "gpt-5.4"))
    assert gpt54.fast?
    assert gpt54.efforts == ~w(low medium high xhigh)
    assert gpt54.default_effort == "medium"

    refute Enum.find(models, &(&1.id == "gpt-5.4-mini")).fast?
  end

  test "a custom :codex_model outside the catalog still shows up in the list" do
    Application.put_env(:catalyst, :codex_model, "my-custom-model")
    on_exit(fn -> Application.delete_env(:catalyst, :codex_model) end)

    entry = Enum.find(OpenAICodex.list_models(), &(&1.id == "my-custom-model"))
    assert entry.name == "my-custom-model"
    refute entry.fast?
  end

  test ":codex_models config overrides the catalog; catalog_entry falls back for unknown ids" do
    Application.put_env(:catalyst, :codex_models, [%{id: "alt-model", fast?: true}])
    on_exit(fn -> Application.delete_env(:catalyst, :codex_models) end)

    assert [%{id: "alt-model", fast?: true}, %{id: "gpt-5.4"}] = OpenAICodex.list_models()
    assert OpenAICodex.catalog_entry("nope").efforts == ~w(low medium high xhigh)
  end

  test "model/1 uses the catalog display name" do
    assert OpenAICodex.model("gpt-5.4").name == "GPT-5.4"
    assert OpenAICodex.model("unknown-id").name == "unknown-id"
  end

  test "live catalog parsing keeps every context field but never invents max_tokens" do
    [entry] =
      OpenAICodex.parse_live_models([
        %{
          "slug" => "context-model",
          "display_name" => "Context model",
          "visibility" => "list",
          "context_window" => 300_000,
          "max_context_window" => 400_000,
          "effective_context_window_percent" => 95,
          "auto_compact_token_limit" => 250_000
        }
      ])

    assert entry.context_window == 300_000
    assert entry.max_context_window == 400_000
    assert entry.effective_context_window_percent == 95
    assert entry.auto_compact_token_limit == 250_000
    refute Map.has_key?(entry, :max_tokens)

    [invalid] =
      OpenAICodex.parse_live_models([
        %{
          "slug" => "invalid-context",
          "visibility" => "list",
          "context_window" => 0,
          "max_context_window" => -1,
          "effective_context_window_percent" => 101,
          "auto_compact_token_limit" => "large"
        }
      ])

    assert invalid.context_window == nil
    assert invalid.max_context_window == nil
    # Missing or invalid percentages normalize to Codex's documented 95%
    # default at the catalog boundary, per qq.md §2a.
    assert invalid.effective_context_window_percent == 95
    assert invalid.auto_compact_token_limit == nil
  end

  test "model/2 uses effective catalog metadata, including max-window-only entries" do
    Application.put_env(:catalyst, :codex_models, [
      %{
        id: "max-only",
        max_context_window: 400_000,
        effective_context_window_percent: 90,
        auto_compact_token_limit: 350_000
      }
    ])

    on_exit(fn -> Application.delete_env(:catalyst, :codex_models) end)

    model = OpenAICodex.model("max-only")
    assert model.context_window == 400_000
    assert model.max_context_window == 400_000
    assert model.effective_context_window_percent == 90
    assert model.auto_compact_token_limit == 350_000
    assert model.context_window_source == :catalog
    assert model.max_tokens == 128_000

    explicit = OpenAICodex.model("max-only", context_window: 123_000)
    assert explicit.context_window == 123_000
    assert explicit.context_window_source == :session

    invalid_override = OpenAICodex.model("max-only", context_window: 0)
    assert invalid_override.context_window == 400_000
    assert invalid_override.context_window_source == :catalog
  end

  # Shaped like codex-rs models-manager/models.json entries.
  @live_payload [
    %{
      "slug" => "gpt-6",
      "display_name" => "GPT-6",
      "visibility" => "list",
      "priority" => 0,
      "service_tiers" => [
        %{"id" => "priority", "name" => "Fast", "description" => "1.5x speed"}
      ],
      "supported_reasoning_levels" => [
        %{"effort" => "low", "description" => "low"},
        %{"effort" => "medium", "description" => "medium"},
        %{"effort" => "ultra", "description" => "ultra"}
      ],
      "default_reasoning_level" => "medium",
      "context_window" => 400_000
    },
    %{
      "slug" => "codex-auto-review",
      "display_name" => "Auto review",
      "visibility" => "hide",
      "priority" => 29
    },
    %{
      "slug" => "gpt-6-mini",
      "display_name" => "GPT-6 mini",
      "visibility" => "list",
      "priority" => 4,
      "additional_speed_tiers" => []
    }
  ]

  test "parse_live_models keeps list-visible models sorted by priority with tiers/efforts" do
    assert [gpt6, mini] = OpenAICodex.parse_live_models(@live_payload)

    assert gpt6.id == "gpt-6"
    assert gpt6.name == "GPT-6"
    assert gpt6.fast?
    assert gpt6.efforts == ~w(low medium ultra)
    assert gpt6.default_effort == "medium"

    assert mini.id == "gpt-6-mini"
    refute mini.fast?
    # No levels advertised — fall back to the bundled effort list.
    assert mini.efforts == ~w(low medium high xhigh)
  end

  test "a cached live catalog is served by list_models; :codex_models still wins" do
    :ok = CatalogCache.store(OpenAICodex.parse_live_models(@live_payload))

    ids = OpenAICodex.list_models() |> Enum.map(& &1.id)
    assert "gpt-6" in ids
    # The configured default id is still appended.
    assert "gpt-5.4" in ids

    Application.put_env(:catalyst, :codex_models, [%{id: "pinned-model"}])
    on_exit(fn -> Application.delete_env(:catalyst, :codex_models) end)

    ids = OpenAICodex.list_models() |> Enum.map(& &1.id)
    assert "pinned-model" in ids
    refute "gpt-6" in ids
  end

  test "catalog_snapshot resolves the selected entry with one cache read" do
    cache = Process.whereis(CatalogCache)
    :erlang.trace(cache, true, [:receive])
    on_exit(fn -> :erlang.trace(cache, false, [:receive]) end)

    %{models: models, selected: selected} =
      OpenAICodex.catalog_snapshot(OpenAICodex.default_model_id())

    assert selected.id == OpenAICodex.default_model_id()
    assert selected in models

    assert_receive {:trace, ^cache, :receive, {:"$gen_call", _from, :models}}
    refute_receive {:trace, ^cache, :receive, {:"$gen_call", _from, :models}}
  end

  defmodule ModelsStub do
    import Plug.Conn

    def init(opts), do: opts

    def call(conn, test) do
      conn = fetch_query_params(conn)
      send(test, {:models_request, conn.request_path, conn.query_params, conn.req_headers})

      payload = %{
        "models" => [
          %{
            "slug" => "gpt-6",
            "display_name" => "GPT-6",
            "visibility" => "list",
            "priority" => 0,
            "service_tiers" => [%{"id" => "priority", "name" => "Fast"}]
          }
        ]
      }

      conn
      |> put_resp_header("etag", "models-v1")
      |> put_resp_content_type("application/json")
      |> send_resp(200, Jason.encode!(payload))
    end
  end

  test "fetch_live_models parses the endpoint response (client_version + auth headers sent)" do
    {:ok, server} =
      Bandit.start_link(
        plug: {ModelsStub, self()},
        scheme: :http,
        port: 0,
        ip: {127, 0, 0, 1},
        startup_log: false
      )

    {:ok, {_addr, port}} = ThousandIsland.listener_info(server)

    assert {:ok, [%{id: "gpt-6", fast?: true}], etag} =
             OpenAICodex.fetch_live_models("tok", "acct", "http://127.0.0.1:#{port}")

    assert etag == "models-v1"

    assert_receive {:models_request, "/codex/models", params, headers}
    assert %{"client_version" => _version} = params
    assert {"authorization", "Bearer tok"} in headers
    assert {"chatgpt-account-id", "acct"} in headers
    assert {"originator", "codex_cli_rs"} in headers
  end

  test "notice_models_etag renews the monotonic TTL on a match and refetches on change" do
    test = self()
    control = start_supervised!({Agent, fn -> %{now: 0, fetches: 0} end})
    entries = OpenAICodex.parse_live_models(@live_payload)

    fetcher = fn ->
      fetch =
        Agent.get_and_update(control, fn state ->
          {state.fetches + 1, %{state | fetches: state.fetches + 1}}
        end)

      send(test, {:catalog_fetch, fetch})
      {:ok, entries, "models-v#{fetch}"}
    end

    clock = fn -> Agent.get(control, & &1.now) end

    cache =
      start_supervised!(
        {CatalogCache,
         name: nil,
         fetcher: fetcher,
         clock: clock,
         enabled?: fn -> true end,
         ttl_ms: 100,
         retry_ms: 0}
      )

    assert {:ok, ^entries} = CatalogCache.refresh(cache)
    assert_receive {:catalog_fetch, 1}

    Agent.update(control, &%{&1 | now: 150})
    :ok = CatalogCache.notice_etag("models-v1", cache)
    _state = :sys.get_state(cache)

    assert ^entries = CatalogCache.models(cache)
    refute_receive {:catalog_fetch, 2}, 50

    :ok = CatalogCache.notice_etag("models-v2", cache)
    assert_receive {:catalog_fetch, 2}
  end

  test "catalog refresh is single-flight across concurrent automatic triggers" do
    test = self()
    entries = OpenAICodex.parse_live_models(@live_payload)

    fetcher = fn ->
      send(test, {:catalog_fetch_started, self()})

      receive do
        :finish_catalog_fetch -> {:ok, entries, "models-v1"}
      end
    end

    cache =
      start_supervised!(
        {CatalogCache, name: nil, fetcher: fetcher, enabled?: fn -> true end, retry_ms: 0}
      )

    assert [] = CatalogCache.models(cache)
    assert_receive {:catalog_fetch_started, worker}
    monitor = Process.monitor(worker)

    assert [] = CatalogCache.models(cache)
    :ok = CatalogCache.notice_etag("models-v2", cache)
    _state = :sys.get_state(cache)
    refute_receive {:catalog_fetch_started, _other}, 50

    send(worker, :finish_catalog_fetch)
    assert_receive {:DOWN, ^monitor, :process, ^worker, :normal}
  end

  test "catalog refresh kills a hung fetch and releases its waiters" do
    test = self()

    fetcher = fn ->
      send(test, {:hung_catalog_fetch, self()})

      receive do
        :never -> {:ok, [], nil}
      end
    end

    cache =
      start_supervised!(
        {CatalogCache,
         name: nil, fetcher: fetcher, enabled?: fn -> true end, refresh_timeout_ms: 50}
      )

    _caller =
      start_supervised!(
        {Task,
         fn ->
           send(test, {:hung_catalog_result, CatalogCache.refresh(cache)})
         end}
      )

    assert_receive {:hung_catalog_fetch, worker}
    monitor = Process.monitor(worker)

    assert_receive {:hung_catalog_result, {:error, :timeout}}, 1_000
    assert_receive {:DOWN, ^monitor, :process, ^worker, :killed}

    state = :sys.get_state(cache)
    assert state.refresh == nil
    assert state.refresh_timer == nil
    assert state.waiters == []
  end

  test "a completed catalog refresh queued at the timeout boundary is preserved" do
    test = self()
    entries = OpenAICodex.parse_live_models(@live_payload)

    fetcher = fn ->
      send(test, {:boundary_catalog_fetch, self()})

      receive do
        :finish_boundary_catalog_fetch -> {:ok, entries, "models-boundary"}
      end
    end

    cache =
      start_supervised!({CatalogCache, name: nil, fetcher: fetcher, enabled?: fn -> true end})

    on_exit(fn -> resume_if_suspended(cache) end)

    _caller =
      start_supervised!(
        {Task,
         fn ->
           send(test, {:boundary_catalog_result, CatalogCache.refresh(cache)})
         end}
      )

    assert_receive {:boundary_catalog_fetch, worker}, 1_000
    %{refresh: %Task{ref: ref}} = :sys.get_state(cache)
    monitor = Process.monitor(worker)
    :ok = :sys.suspend(cache)

    send(cache, {:refresh_timeout, ref})
    send(worker, :finish_boundary_catalog_fetch)
    assert_receive {:DOWN, ^monitor, :process, ^worker, :normal}, 1_000

    :ok = :sys.resume(cache)

    assert_receive {:boundary_catalog_result, {:ok, ^entries}}, 1_000
    assert ^entries = CatalogCache.models(cache)
    assert %{etag: "models-boundary", refresh: nil, waiters: []} = :sys.get_state(cache)
  end

  test "disabling live catalogs preserves cached entries and ignores automatic triggers" do
    test = self()
    entries = OpenAICodex.parse_live_models(@live_payload)
    fetcher = fn -> send(test, :unexpected_catalog_fetch) end

    cache =
      start_supervised!({CatalogCache, name: nil, fetcher: fetcher, enabled?: fn -> false end})

    :ok = CatalogCache.store(entries, server: cache, etag: "models-v1")

    assert ^entries = CatalogCache.models(cache)
    :ok = CatalogCache.notice_etag("models-v2", cache)
    _state = :sys.get_state(cache)
    refute_receive :unexpected_catalog_fetch
  end

  defp resume_if_suspended(server) do
    case Process.info(server, :status) do
      {:status, :suspended} -> :sys.resume(server)
      _not_suspended -> :ok
    end
  end
end
