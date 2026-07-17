# Catalyst — Architecture

Catalyst is an Elixir/OTP reimplementation of **PI** (a minimal coding-agent harness,
originally TypeScript — see `./tmp_pi`), delivered as a **native desktop GUI** via
[`elixir-desktop/desktop`](https://github.com/elixir-desktop/desktop) (wxWidgets + Phoenix
LiveView). It keeps PI's minimal agent surface but swaps in fast Rust tools and adds
structural code editing:

- **ripgrep** for grep, **fd** for find, **sd** for sed, **ast-grep** (tree-sitter) for
  structural/AST code edits.
- A pluggable LLM provider layer, **starting with OpenAI Codex (ChatGPT subscription,
  OAuth)**, designed to grow toward PI's full provider breadth.

> Toolchain status on the dev machine (verified): Erlang/OTP 29, Elixir 1.20, `:wx`
> **available**, and `rg`/`fd`/`sd`/`ast-grep` all installed.

**Beyond PI parity — "modify everything at runtime."** Catalyst leans on BEAM hot code loading
to make the running app self-modifiable: *everything is a registry + hooks + hot-swap.* Tools,
LLM providers, agent-loop hooks, and the UI (pages, renderers, panels, CSS/JS) are each an
ETS-backed registry, seeded from built-ins at boot and writable at runtime through one unified
`Catalyst.ExtensionAPI`. The agent compiles and loads new modules into the live VM (the Elixir
compiler ships in the release) and uses them on the next turn/render — **even inside the
packaged `.app`**. This is the subject of **§11**; the rest of the document describes the PI
core those registries sit on top of. The umbrella also carries a 4th app, **`catalyst_cli`**, a
headless (no-wx) release used to prove packaged hot-loading.

---

## 1. How PI works (the surface we reproduce)

PI is an npm monorepo: `agent` (core loop + state), `ai` (multi-provider LLM streaming),
`coding-agent` (tools + CLI/TUI harness), `tui` (terminal UI).

- **Agent loop** (`tmp_pi/packages/agent/src/agent-loop.ts`): user message → stream
  assistant response from the LLM → if it has tool calls, execute them (sequential or
  parallel) → append tool results → repeat until no tool calls. Emits fine-grained events:
  `agent_start`, `turn_start`, `message_start|update|end`,
  `tool_execution_start|update|end`, `turn_end`, `agent_end`. Supports mid-run **steering**
  and post-stop **follow-up** queues, a `terminate` flag on a tool batch, and per-turn hooks
  (`beforeToolCall`, `afterToolCall`, `prepareNextTurn`, `shouldStopAfterTurn`).
- **Stateful `Agent`** (`agent.ts`): owns mutable state (system prompt, model, messages,
  pendingToolCalls, streamingMessage) plus a subscribe/listener model; the loop is a
  function it invokes, and events fold back into state via `processEvents`.
- **Tools** (`packages/coding-agent/src/core/tools/`): each =
  `{name, description, parameters (JSON schema), execute(id, params, signal, onUpdate) ->
  {content, details, terminate?}}`. Built-ins: `read`, `write`, `edit` (oldText/newText
  fuzzy replace), `bash` (streaming, tail-truncate, process-tree kill), `grep` (`rg --json`),
  `find` (`fd`), `ls`. Thrown exceptions become error tool-results; output truncated to
  2000 lines / 50KB. Missing binaries auto-downloaded (`utils/tools-manager.ts`).
- **LLM providers** (`packages/ai/src/`): keyed by an `api` type; each implements
  `streamSimple(model, context, options)` returning an event stream.
  `Context = {systemPrompt, messages, tools}`.
- **OpenAI Codex** (verified in `providers/openai-codex-responses.ts` &
  `utils/oauth/openai-codex.ts`): Responses API at
  `https://chatgpt.com/backend-api/codex/responses`, SSE streaming. Headers
  `Authorization: Bearer <access>`, `chatgpt-account-id: <id>`, `originator`,
  `OpenAI-Beta: responses=experimental`, `x-client-request-id: <sessionId>`. Auth = ChatGPT
  OAuth **PKCE** (CLIENT_ID `app_EMoamEEZ73f0CkXaXp7hrann`, authorize/token at
  `https://auth.openai.com`, local callback `http://localhost:1455/auth/callback`;
  device-code flow also available). The access token is a JWT whose claim
  `https://api.openai.com/auth.chatgpt_account_id` supplies the account id.

**Load-bearing reference files** each Elixir module must match:
`agent/src/agent-loop.ts`, `agent/src/agent.ts`,
`ai/src/providers/openai-codex-responses.ts`, `ai/src/providers/openai-responses-shared.ts`,
`ai/src/utils/oauth/openai-codex.ts`, `coding-agent/src/core/tools/{grep,bash,edit,find}.ts`,
`coding-agent/src/core/tools/truncate.ts`, `coding-agent/src/utils/tools-manager.ts`.

---

## 2. Umbrella layout

```
catalyst/                      # umbrella
  apps/
    catalyst/                  # headless core — NO Phoenix dep (only phoenix_pubsub)
      lib/catalyst/
        message.ex content.ex model.ex usage.ex   # data model (mirror ai/src/types.ts)
        tasks.ex paths.ex ids.ex                   # shared task, path, and identifier helpers
        files/atomic_write.ex                      # shared atomic replacement + mode preservation
        agent/{event.ex, loop.ex, tool_runner.ex}
        hooks.ex hooks/{table_owner.ex, observer_dispatcher.ex}
                                                   # hook registry + ordered bounded event observers (§11)
        system_prompt.ex                           # system prompt as data (§11)
        extension.ex extension_api.ex              # extension behaviour + unified API (§11)
        extensions.ex                              # multi-kind loader (§11)
        extensions/{versioning.ex, boot_guard.ex, processes.ex,
                    installer.ex, loader.ex, compiler_tracer.ex, module_scan.ex}
                                                   # git versioning + crash-safe boot + isolated loading
                                                   # + shared write→load→commit pipeline w/ self-mod kill switch (§11)
        debug.ex                                   # per-session debug log (§12)
        session/{server.ex, manager.ex, store.ex,
                 reducer.ex, run_config.ex, snapshot.ex,
                 server/state.ex, store/codec.ex}  # thin server + extracted state/codec + hot-swap logic
        tools/{tool.ex, registry.ex, exec.ex, binaries.ex, truncate.ex, paths.ex, diff.ex,
               atomic_write.ex,                    # compatibility facade for files/atomic_write.ex
               read.ex, write.ex, edit.ex, ls.ex, bash.ex,
               ripgrep.ex, fd.ex, sd.ex, ast_grep.ex,
               develop_tool.ex, install_extension.ex, reload_tool.ex,
               rollback_tool.ex, read_log.ex}      # …+ self-modification tools (§11)
        llm/{provider.ex, provider_config.ex, registry.ex, event.ex, context.ex,
             sse.ex, faux.ex, demo.ex, openai_codex.ex,
             openai_codex/{bounded_buffer.ex, catalog.ex, catalog_cache.ex, catalog_cache/state.ex,
                           conn_cache.ex, provider.ex,
                           request.ex, sse_transport.ex, stream_parser.ex, headers.ex,
                           web_socket.ex}}
        auth/{token_store.ex, openai_oauth.ex, callback_server.ex,
              callback_server/handler.ex, jwt.ex, pkce.ex}
        application.ex
    catalyst_web/              # Phoenix + LiveView — catch-all shell + UI registries
      lib/catalyst_web/
        {endpoint.ex, router.ex, application.ex, assets.ex}
        file_search.ex                             # "@" file references for the chat input (fd-backed)
        live/shell_live.ex                         # ONE LiveView; catch-all routes / and /:page
        pages/chat_page.ex                         # the chat as a registry-registered page
        pages/extensions_page.ex                   # extensions/settings panel (also a seeded page, §11)
        ui/{registry.ex, message_renderer.ex}      # pages/renderers/components/commands (§11)
        tools/{rebuild_assets.ex, reconnect_ui.ex} # web-side self-mod tools (§11)
        components/* controllers/*
    catalyst_desktop/          # Desktop.Window child + release/packaging (depends on web)
      lib/catalyst_desktop.ex
    catalyst_cli/              # headless (no-wx) release — proves packaged hot-loading
      lib/catalyst_cli.ex
  rel/macos/launcher.c         # native arm64 .app launcher (§8)
  config/{config.exs, dev.exs, prod.exs, runtime.exs}
```

The boundary is enforced by app dependencies: `catalyst` carries no Phoenix; `catalyst_web`
depends on `catalyst`; `catalyst_desktop` depends on `catalyst_web`. This keeps the agent
core runnable headless (iex/escript/tests) and lets the LLM core be extracted later. The core
never references `catalyst_web` directly — UI extension *kinds* are dispatched through
`:persistent_term` (§11) so the dependency arrow only ever points web → core.

---

## 3. Supervision tree

```
Catalyst.Application (top, in apps/catalyst)
├── {DNSCluster, ...}
├── {Phoenix.PubSub, name: Catalyst.PubSub}
├── {Finch, name: Catalyst.Finch}                 # SSE streaming + token HTTP
├── {Task.Supervisor, name: Catalyst.TaskSupervisor}        # run, hook, metadata, refresh tasks
├── Catalyst.Tools.Registry                     # validated, fingerprinted tool-definition cache
├── Catalyst.Auth.TokenStore                      # GenServer, single-flight token refresh
├── Catalyst.LLM.OpenAICodex.CatalogCache         # live model metadata, single-flight refresh
├── Catalyst.LLM.OpenAICodex.ConnCache            # idle Codex ws conns between runs (delta-upload state, §6)
├── ExtensionRuntimeSupervisor (:rest_for_one)    # order load-bearing: a crash restarts everything after it
│   ├── Catalyst.Hooks.TableOwner                 # owns the hooks ETS table (handlers survive a Hooks crash)
│   ├── Catalyst.Hooks                            # ETS agent-loop hook registry (§11)
│   ├── Catalyst.Hooks.ObserverDispatcher         # ordered, bounded async event observers
│   ├── Catalyst.LLM.Registry                     # ETS provider registry: built-ins + runtime (§11)
│   ├── {Registry, keys: :unique, name: Catalyst.Extensions.ProcessRegistry}  # owner -> ext supervisor (§11)
│   ├── {DynamicSupervisor, name: Catalyst.Extensions.ProcessSupervisor}      # extension-owned processes (§11)
│   └── Catalyst.Extensions                       # last: its load_all re-registers into the ones above (§11)
├── {Registry, keys: :unique, name: Catalyst.Session.Registry}
└── {DynamicSupervisor, name: Catalyst.Session.DynamicSupervisor}   # one Session.Server per session
                                                  # (outside the group: sessions ride out a registry restart)

CatalystWeb.Application (in catalyst_web)
├── CatalystWeb.Telemetry
├── CatalystWeb.UI.Registry                        # ETS UI registry: pages/renderers/components/commands (§11)
└── CatalystWeb.Endpoint                           # + register_web_tools/0 after boot (rebuild_assets/reload_ui,
                                                   #   registered as an Extensions reseeder so restarts re-add them)

Catalyst.Desktop (Desktop.Window child)           # started by catalyst_desktop, desktop mode only

# per session: Session.Manager starts a Catalyst.Session.Server (GenServer, PI Agent analog)
# directly under Catalyst.Session.DynamicSupervisor; loop/tool Tasks run under the shared
# Catalyst.TaskSupervisor (abort = kill the run Task; linked tool Tasks + their Ports die).
```

`Catalyst.Extensions`, `Catalyst.Hooks`, and `Catalyst.LLM.Registry` boot **before** any session
so the very first turn sees built-ins; each is an ETS-backed GenServer read live on each use, so a
runtime registration takes effect on the next turn/render with no restart (§11).

---

## 4. Process model (maps directly onto PI)

- **`Session.Server`** = PI's `Agent`: the single writer of transcript / model / queues /
  pending state. API: `prompt/2`, `continue/1`, `steer/2`, `follow_up/2`, `abort/1`,
  `state/1`, `reset/1`. "Subscribe" = the caller subscribes to PubSub topic `"session:<id>"`.
  The server is deliberately **thin**: event fold/reduce (`Session.Reducer`), run-config assembly +
  provider resolution (`Session.RunConfig`), and snapshotting for late joiners (`Session.Snapshot`)
  live in stateless, hot-swappable modules it delegates to — so deep behavior changes are module
  reloads, not session restarts. The struct definition lives in `Session.Server.State`; the
  queues and state ownership remain in the GenServer callbacks (additive `%State{}` fields are
  free; destructive changes need `code_change/3` or a rebuild-from-JSONL).
- **`Agent.Loop.run(prompts, context, config, emit)`** = `agent-loop.ts`: a plain recursive
  function run through `Catalyst.Tasks.async/1` under the shared task supervisor. `emit` casts
  a run-ref-scoped `{:agent_event, ...}`
  to `Session.Server`, which folds it into state (like `processEvents`), persists on
  `message_end`, and `Phoenix.PubSub.broadcast`s it to subscribers. The loop calls back into
  `Session.Server` for queue draining and the tool hooks. PI-parity semantics worth naming:
  steering is re-checked after **every** turn (a steer landing during the final toolless turn
  runs another turn instead of sitting queued); a tool batch terminates the loop only when
  **every** call asked to; a provider error/abort ends the run immediately **without**
  draining follow-ups; `prepare_next_turn`/`should_stop_after_turn` run after every turn, and
  a `should_stop` veto also skips the follow-up queue. (There is no `get_api_key` config —
  the Codex provider fetches a fresh token per attempt from `Auth.TokenStore` itself.)
- **Cancellation = process kill** (no AbortSignal): `abort` kills the run Task; linked tool
  tasks die; their linked Ports / MuonTrap daemons kill the OS process group. On an abnormal
  `:DOWN`, `Session.Server` synthesizes an aborted/error Assistant turn (PI's
  `handleRunFailure`).
- **`ToolRunner`**: sequential vs parallel batch (parity with PI — any tool with
  `execution_mode: :sequential`, or a config flag, forces sequential). Validates args against
  the tool's JSON schema (`ex_json_schema`), runs each tool in a supervised Task; a crash
  becomes an error tool-result (the "thrown becomes error result" rule). The `onUpdate`
  callback is a closure (`ctx.report`) that emits `ToolExecutionUpdate`; `bash` streams a
  bounded output tail through it, throttled in-tool to one report per 100ms.

### Event flow to the UI

```
Loop Task ──cast {:agent_event, e}──▶ Session.Server (reduce state)
                                        └─ PubSub.broadcast "session:<id>" ─▶ ChatLive(s)
```

The chat input supports **`@` file references** (`CatalystWeb.FileSearch`, fd-backed): a
trailing `@query` opens a candidate dropdown; picking inserts a short label
(`@<parent>/<name>`, extended upward only as needed to disambiguate same-named files), and on
send the labels expand to cwd-relative paths for the model. **Pasted screenshots** attach to
the prompt: a `PasteImages` JS hook feeds clipboard images into a LiveView upload (chips with
previews/progress above the input, ≤4 images, ≤5MB each), and send builds a user message with
`Content.Image` blocks (thumbnails in the user bubble; `input_image` parts in the Codex
request). `/name [arg]` messages dispatch through the **commands registry** (§11) — `/cd` is
the seeded built-in; unknown commands flash the known list rather than reaching the model.

`ShellLive.mount` attaches to (or starts) the session, **subscribes first, then** replays the
snapshot (`Session.Server.state/1`) with a small dedup window (and flushes already-queued
`MessageUpdate`s ≤ the snapshot), so no event is lost or doubled around the reattach. The
message list uses LiveView `stream/3`. **Streaming renders live with block-commit markdown**
(the Codex CLI's strategy adapted to LiveView): each text/thinking delta is `push_event`ed to
a client-side `StreamingMessage` hook that appends into a `phx-update="ignore"` raw tail; on
newline-carrying deltas the server re-parses the accumulated text with
`UI.Markdown.stable_split/1` — every block except the last is **stable** (newline gating +
line-anchored classification make commits monotone; a trailing fence-closed code block
commits immediately) — and newly stabilized blocks render ONCE through the real
`MessageRenderer` into a per-message stream inside the bubble, while a `stream_tail` event
trims the raw tail to the open block's source. Fenced code gets **syntax highlighting**
(vendored highlight.js via the `Highlight` hook — explicit fence language only, input via
`textContent`) the moment its fence closes, and the `message_end` swap to the final message
renders the same blocks through the same pipeline — visually a no-op. A late joiner seeds
committed blocks + tail from the snapshot's `streaming_message`. Tool spinners show a live
output tail streamed by `bash` via `ToolExecutionUpdate`. A header **Quiet** toggle
(display-only, persisted in its own persistent_term separate from the Codex prefs) sets
`data-quiet` on the transcript container; CSS rules in `app.css` then hide tool chips,
tool-result cards, and thinking — CSS rather than re-render because stream/ignore regions
never re-render on assign changes. Spinners stay visible; the session is never touched.

---

## 5. Tools

```elixir
defmodule Catalyst.Tools.Tool do
  @callback name() :: String.t()
  @callback description() :: String.t()
  @callback parameters() :: map()                       # JSON Schema, passed to the provider
  @callback execution_mode() :: :parallel | :sequential
  @callback execute(args :: map(), ctx :: map()) ::
              %{content: [Catalyst.Content.t()], details: map(), terminate: boolean()}
  # ctx = %{cwd, call_id, report: (partial -> :ok)}; raise on failure -> error tool-result
end
```

`Catalyst.Exec` wraps two shell-out modes:

- **`collect/3`** — plain `Port` `{:spawn_executable, ...}`, accumulate stdout, parse after
  exit, receive-after timeout. Used by the single-shot structured tools.
- **`bash/2`** — the muontrap wrapper binary (driven directly over a Port) for reliable
  process-group SIGKILL + timeout. Used by `bash`. Both modes accept `:on_output`
  (crash-isolated per-chunk observer) — `bash` uses it to stream a throttled partial-output
  tail through `ctx.report`.

`Catalyst.Tools.Binaries` resolves `rg`/`fd`/`ast-grep`/`sd` from `~/.catalyst/bin`, the
bundled `priv/bin` (packaged app), `PATH`, then Homebrew paths (cached in
`:persistent_term`). Per-OS/arch **auto-download** à la PI's `ensureTool` is deferred —
today a missing binary raises with an install hint.

`Catalyst.Tools.Registry` validates a tool's name/description/schema once at registration and
caches the result under the module's BEAM fingerprint. Turn assembly reads that cache; a hot-code
change invalidates the fingerprint and forces one bounded revalidation, rather than spawning a
task for every tool on every turn. Invalid/stale metadata is logged and the tool is omitted.

`Catalyst.Agent.ToolRunner` validates each call's args against the tool's declared JSON
Schema (`ex_json_schema`) before executing — a malformed call (most common with
self-developed tools) becomes a clean error tool-result the model can correct, not a
crash inside `execute/2`. An unresolvable schema skips validation rather than blocking.

| Tool | Backend | Notes |
|---|---|---|
| `read` `write` `ls` | pure Elixir `File` | line offset/limit, truncate 2000/50KB; image files (jpg/png/gif/webp by magic bytes) return base64+mime content blocks (≤5MB; no resizing) |
| `edit` | pure Elixir | oldText/newText exact replace with PI's **fuzzy fallback** (NFKC + trailing-whitespace/smart-quote/dash/space normalization; any fuzzy edit rewrites the file in normalized space), unified diff (`Tools.Diff`) in content + `details` |
| `bash` | MuonTrap | `bash -c` (fallback `sh -c`; no `-l` — no login-profile sourcing), tail-truncate, 100ms-throttled live output tail via `ctx.report` (temp-file spill deferred) |
| `grep` | ripgrep `collect` | `rg --json --line-number --color=never --hidden [flags] -- PATTERN PATH`; parse `type:"match"`; cap at limit |
| `find` | fd `collect` | `fd --color never [--hidden] [--glob] PATTERN PATH` |
| `replace` | sd `collect` | `sd [--string-mode] PATTERN REPL FILE…`; unified diff (pre/post read) in content + `details` |
| `ast_grep` | ast-grep `collect` | search: `ast-grep run --pattern P --lang L --json=stream PATH`; rewrite: add `--rewrite R --update-all`. Two sub-actions chosen by presence of a `rewrite` arg. Resolve the binary as `ast-grep` (not `sg`). |
| `develop_tool` `install_extension` `reload_extensions` `rollback_extension` `read_log` | `Catalyst.Extensions` / `Debug` | **self-modification tools** (§11/§12): write+load a tool or any extension module, reload/rollback the extensions dir, read this session's debug log. Web boot also registers `rebuild_assets` + `reload_ui`. |

Tool path args are resolved via `Catalyst.Tools.Paths` (expand `~`, resolve relative to the
session `cwd`). The default tool list lives in `Catalyst.Tools.Registry`; the **live** set per turn
comes from `Catalyst.Extensions` (built-ins + loaded extensions), resolved fresh each turn.

---

## 6. LLM provider + OpenAI Codex

```elixir
defmodule Catalyst.LLM.Provider do
  @callback stream(model, context, opts, sink :: (Catalyst.LLM.Event.t -> any)) ::
              {:ok, Catalyst.Message.Assistant.t} | {:error, term}
  # NEVER raise; encode failures as an Error event with stop_reason :error
  # (aborts are a process-kill at the session layer, not a provider event).
  @callback cleanup_session(session_id :: String.t()) :: :ok
  @optional_callbacks cleanup_session: 1
end
```

`Catalyst.LLM.Faux` replays scripted events (including tool calls) so the entire loop is
testable with no network — built before the real provider. `Catalyst.LLM.Demo` is an offline,
input-aware provider (runs a real `ls`/`grep`/`find` then word-streams a reply) with **no UI
surface**: the app's only real provider is Codex; LiveView tests inject Demo as the session
provider via `config :catalyst_web, :codex_provider_mod` to drive full turns offline.

Providers are resolved through **`Catalyst.LLM.Registry`** (ETS-GenServer), keyed by `api` name
and seeded with the built-ins (`faux`, `openai-codex-responses`). A session resolves its provider
by module or by api-name; new providers are added at runtime with
`register_provider(api, %Catalyst.LLM.ProviderConfig{…})` (or a bare module), and recompiling a
provider module changes behavior on the next `stream/4` with no restart (§11).

**`Catalyst.LLM.OpenAICodex`** (verified against PI source + the Codex CLI, `openai/codex`):
- URL `https://chatgpt.com/backend-api/codex/responses`.
- **Model catalog** (`OpenAICodex.list_models/0`): `config :catalyst, :codex_models` override
  wins; else the **live list** from `GET <base>/codex/models?client_version=…` (fetched in a
  background task when authenticated, 5-min TTL, `visibility: "list"` models sorted by
  priority, Fast from `service_tiers`, efforts from `supported_reasoning_levels`; disabled by
  `:codex_live_models, false` — set in test). Freshness follows the CLI's **`x-models-etag`**
  signal: every /responses response (SSE headers and the ws upgrade) is checked — a matching
  etag just renews the cache TTL, a new one forces a background refetch. Else the bundled list — gpt-5.5 / gpt-5.4 (both
  "Fast"-capable) / gpt-5.4-mini / gpt-5.3-codex / gpt-5.2, efforts low/medium/high/xhigh
  (default medium), all vision-capable (`input: [:text, :image]`). A custom `:codex_model` id
  is always included. The toolbar reads models plus defaults through one consistent
  `catalog_snapshot/0` call rather than several serialized cache calls per render.
- **Run options** (session opts, set live from the header UI via `Session.Server.configure/2`,
  applied on the next run): `:reasoning_effort`, `:service_tier` (`"priority"` = **Fast mode**,
  ~1.5x speed / increased usage, gpt-5.5 & gpt-5.4 only), `:transport`. `:session_id` is reserved:
  `Session.Server` strips nested caller values and `RunConfig` always installs the validated
  `state.id`, so cache/header/debug/tool identities cannot diverge.
- **Transports** (`opts[:transport]` | `config :catalyst, :codex_transport`, default `:auto`):
  `:websocket` — the CLI's preferred transport (`Catalyst.LLM.OpenAICodex.WebSocket`,
  Mint + mint_web_socket): upgrade on the same path with
  `OpenAI-Beta: responses_websockets=2026-02-06`, ONE `{"type":"response.create", ...body}` text
  frame per turn, Responses events back as JSON text frames (`response.done` normalized to
  `completed`), pings answered with pongs, idle/connect timeouts. Between requests the
  connection lives in **`ConnCache`** (per-session; ownership transferred via
  `Mint.HTTP.controlling_process/2`, idle pings answered there) so it survives run
  boundaries; while a request streams, the run task owns the socket — an abort kills both.
  Every request error, including initial encode/send failure, closes the checked-out socket before
  returning it unusable; rejected upgrade/error bodies share one 64 KiB bounded-buffer helper.
  **Delta uploads** (the CLI's mechanism, connection-scoped `previous_response_id`): after a
  completed response on a live socket, the next turn uploads only the NEW messages (tool
  results, steering, the next prompt) chained to the previous response id — the covered
  transcript prefix and the request's non-input fields are checked first, and ANY mismatch
  (reconnect, model/tool/option change, rewritten history, prior error) falls back to the full
  input. **Prewarm** (`Provider.prewarm/3`, started and tracked by
  `RunConfig.start_prewarm/1` from session init/configure): a full `response.create` with
  `"generate": false` uploads the instructions/context while the user is still typing, so turn 1
  can ride a delta. Starting a run first cancels and joins any unfinished prewarm and invalidates
  its provider resources, preventing a late warmup stash from replacing the run's connection.
  Configure and session termination apply the same tracked cleanup rule.
  `:sse` — POST + event-stream (below). `:auto` — websocket, falling back to SSE when the
  websocket fails before any event reached the sink (after that, the partial turn is finalized
  like an SSE transport close). A ws-upgrade 401 drives the same single token-refresh retry;
  SSE 429/5xx get a bounded retry honoring `retry-after(-ms)` (a 429 without one surfaces the
  friendly usage-limit message from `parseErrorResponse`'s port instead).
- Headers: `Authorization: Bearer`, `chatgpt-account-id`, `originator: "catalyst"`,
  `OpenAI-Beta: responses=experimental` (SSE) or `responses_websockets=2026-02-06` (ws),
  `x-client-request-id: <session id>`, `accept: text/event-stream` (SSE only).
- Body (`buildRequestBody` analog): `model`, `store: false`, `stream: true`, `instructions`
  (system prompt), `input` (Responses items from messages), `tools`
  (`%{type: "function", name, description, parameters}`), `tool_choice: "auto"`,
  `parallel_tool_calls: true`, `include: ["reasoning.encrypted_content"]`,
  `prompt_cache_key: <session id>`, `reasoning: %{effort, summary: "auto"}` when enabled.
- `Catalyst.LLM.SSE`: `Finch.stream` chunk loop → buffer → split `\n\n` frames → parse
  `event:`/`data:` → JSON decode → `on_frame`. 600s `receive_timeout` on the request;
  the provider also handles `Finch.stream/5`'s 3-tuple `{:error, e, partial}` transport
  close (finalizing the partial — see §12).
- `StreamParser` maps Responses events → `Catalyst.LLM.Event` (port
  `openai-responses-shared.ts`): `response.output_text.delta` → TextDelta; reasoning deltas →
  ThinkingDelta; `function_call` item add / `arguments.delta` / done → ToolCall
  start/delta/end; `response.completed` → Done (fill usage, set `:tool_use` if tool calls);
  `response.failed`/`error` → Error. Reasoning item id + `reasoning.encrypted_content` are
  round-tripped on the next request. Retry/usage-limit parsing ported from
  `parseErrorResponse`.

---

## 7. OAuth + token storage

- `Catalyst.Auth.PKCE`: verifier = `Base.url_encode64(strong_rand_bytes(32), padding:
  false)`; challenge = `Base.url_encode64(sha256(verifier), padding: false)`; state = random
  hex.
- `Catalyst.Auth.OpenAIOAuth`: constants verbatim from PI; authorize URL adds
  `id_token_add_organizations=true`, `codex_cli_simplified_flow=true`, `originator`.
- `Catalyst.Auth.CallbackServer`: a transient **Bandit**/Plug server on `127.0.0.1:1455`,
  route `/auth/callback`, validates `state`, captures `code`, returns success/error HTML,
  hands the code to the waiting login process, then shuts down. (A fixed, separate port — not
  the app endpoint.) A new login **supersedes** an abandoned one: the old server is stopped
  (freeing the port immediately) and its waiter gets `{:error, :superseded}` — retrying a
  sign-in no longer collides with the previous attempt's 5-minute wait.
- Code exchange / refresh via `Req.post(TOKEN_URL, form: ...)` (`authorization_code` /
  `refresh_token`). `Catalyst.Auth.JWT` decodes the middle segment (no signature verify) to
  read the account id.
- `Catalyst.Auth.TokenStore` (GenServer): loads `~/.catalyst/auth.json` (chmod 0600);
  `get_access_token/1` refreshes **single-flight** when within a skew of expiry (the loop's
  `get_api_key` calls it each turn); atomic write on update. Its deadline path checks the result
  returned by `Task.shutdown/2` before declaring timeout, so a refresh that completed at the
  timer boundary still persists rotated credentials. `CatalogCache` uses the same boundary rule.

---

## 8. Desktop integration (elixir-desktop)

`CatalystDesktop.Application` adds a `Desktop.Window` child (desktop mode only, guarded by
`config :catalyst_desktop, :start_window` / `CATALYST_DESKTOP=1`):

```elixir
{Desktop.Window, [app: :catalyst_desktop, id: CatalystWindow, title: "Catalyst",
                  size: {1100, 800}, menubar: CatalystDesktop.MenuBar,
                  url: &CatalystWeb.Endpoint.url/0]}
```

This opens a native wx window hosting a `wxWebView` (WKWebView on macOS) pointed at the local
LiveView; the LiveView WebSocket connects back to the same local `CatalystWeb.Endpoint`, so
streaming works over the normal channel. The endpoint binds `127.0.0.1`, `server: true`;
`check_origin` is pinned to the localhost origins in dev (DNS-rebinding guard) and left at
the host-checked default in prod. `Desktop.Auth` (prod only) rejects requests without the
webview's token.

- **Dev (fast loop):** `mix phx.server`, develop the LiveView in a normal browser (no wx
  needed).
- **Desktop dev:** `CATALYST_DESKTOP=1` boots the wx window against the dev endpoint.
- **Packaged:** `MIX_ENV=prod mix assets.build` then `MIX_ENV=prod mix release catalyst_desktop`
  — elixir-desktop `desktop_deployment` builds `_build/prod/Catalyst.{app,dmg,pkg}` (bundles +
  relocates the wxWidgets dylibs; boots the bundled ERTS; ad-hoc signed).

`:wx` must be compiled into the installed Erlang — verified present here.

### Packaging internals (root `mix.exs` release `steps:`)

The desktop release runs custom steps after `:assemble` so the **packaged** app can self-modify:

1. **`bundle_assets/1`** ships a self-contained esbuild/tailwind workspace into the `.app`
   (`<webapp>/priv/asset_build/{assets,lib,bin}` + the JS `deps/` esbuild resolves), so
   `CatalystWeb.Assets.rebuild/0` (§11) regenerates CSS/JS at runtime. `config/{runtime,prod}.exs`
   switch to **no-digest** serving so a runtime rebuild overwrites the served `app.{css,js}`.
   `bundle_fast_tools/1` copies `rg`/`fd`/`sd`/`ast-grep` into `lib/catalyst-*/priv/bin` (a GUI
   `.app` has a minimal PATH; `Tools.Binaries` checks the bundled dir).
2. **`generate_installer/1`** (the dep) builds the `.app` + `.dmg`/`.pkg`.
3. **`native_macos_launcher/1`** fixes a macOS gotcha: `desktop_deployment` makes the
   `CFBundleExecutable` a `#!/bin/bash` script, which has no Mach-O header, so LaunchServices
   mislabels the (entirely arm64) bundle **"Intel"** and prompts for Rosetta. The step compiles a
   tiny native arm64 launcher (`rel/macos/launcher.c`) that `execv`s `run`, ad-hoc signs it
   **before** flipping `CFBundleExecutable` (else codesign tries to seal the whole bundle and fails
   on the unsigned `run`), then rebuilds the `.dmg`/`.pkg` from the fixed app.

Runtime-path rule (in the packaged app): resolve writable locations via `Application.app_dir/2` /
`:code.priv_dir/1`, never hardcoded bundle paths. The session `cwd` defaults to `$HOME` when
`RELEASE_NAME` is set (repoint with the `/cd` chat command). **macOS TCC** blocks a `.app` from
`~/Desktop|Documents|Downloads` (`:eperm`) unless granted Full Disk Access. Caveat: runtime asset
rebuilds need `priv/static` to be user-writable, i.e. run the `.app` from a writable dir (not a
root-owned `/Applications`).

---

## 9. Session persistence

`Catalyst.Session.Store`: append-only JSONL per session at
`~/.catalyst/sessions/<cwd-hash>/<uuid>.jsonl` — a header line, `message` entries, `reset`
markers, and PI's **`model_change` / `thinking_level_change`** entries (appended by
`configure/2` when the model/effort actually changes; `load_state/1` folds transcript and settings
in one pass so a crash-restarted session resumes with the settings it was switched to, independent
of transcript resets). `active_tools_change` is still skipped — tools resolve live per turn.
Skip compaction/branching initially. Append on each `message_end`; rebuild into a
`%Context{}` by folding lines
(port `buildSessionContext`), tolerating corrupt/unknown lines. `Session.Server` calls the
`Store` module directly (a future `ecto_sqlite3` backend means introducing a behaviour then —
it is not behind one today; swapping stores is still just a module hot-swap, §11).

`Catalyst.Paths.home/0` is the shared root for default auth, session, debug, system-prompt,
guide, boot-marker, and downloaded-binary paths. `config :catalyst, :home` relocates that root
explicitly. The narrower `:extensions_dir` override affects only extension source discovery; it
does not silently move credentials or transcripts. Consumer-specific overrides such as
`:auth_path`, `:sessions_root`, and `:system_prompt_path` still win.

---

## 10. Dependencies

- **Core (`apps/catalyst`):** `phoenix_pubsub`, `finch`, `mint_web_socket` (Codex websocket
  transport), `req`, `jason`, `muontrap`, `ex_json_schema`, `bandit`/`plug` (OAuth callback
  server; also the test websocket server via `websock_adapter`, test-only), `dns_cluster`.
- **Web/desktop:** `phoenix`, `phoenix_live_view`, `bandit`, `desktop`, `esbuild`, `tailwind`;
  packaging via `desktop_deployment` (GUI `.app`) and `burrito` (headless `catalyst_cli`).
- **Later:** `joken` (verified JWT), `ecto_sqlite3`.
- **Note:** runtime extensibility (§11) added **no new deps** — it is plain BEAM hot code loading
  (`Code.compile_file/1` + ETS registries), which is exactly why it works inside the packaged app.

---

## 11. Runtime extensibility (registries + hooks + hot-swap)

*Everything is a registry + hooks + hot-swap.* Each extension point is an ETS-backed registry,
seeded from built-ins at boot, written through owner-aware registration APIs (extension setup uses
the unified facade), and read live on each use.
The enabler is BEAM hot code loading: behavior lives in plain modules the loop/UI call fresh, so
loading a new version changes behavior on the next call/render — even in the packaged release (the
Elixir compiler ships in it). Self-modification is **auto-allowed**; the safety net is **bounded
compile with exact accepted-BEAM restoration + git versioning + safe-mode boot (manual AND
automatic, see below)** (no approval cards — an approval gate can be added *as an extension* via
the `before_tool_call` hook). Compilation occurs in the live VM, so it is not a side-effect-free
dry run: emitted modules are immediately installed and must be restored if a later expression in
the file fails.

**Unified API.** `Catalyst.Extension` is a behaviour (`setup(api) :: :ok | {:error, term}`, plus
optional `metadata/0` — merged into `Extensions.list_loaded/0` and shown on the `/extensions`
panel). `Catalyst.ExtensionAPI` is the facade an extension's `setup/1` receives —
`register_tool` / `register_provider` / `register_hook` / `on` / `register_renderer` /
`register_component` / `register_page` / `register_command` / `start_child` — each tagged with the
owning file's `ext_id`. Web-only kinds (renderers/components/pages/commands) are dispatched through
`:persistent_term` so **core never depends on `catalyst_web`**. Direct host registrations use the
reserved `:host` owner; they may refresh their own names but cannot detach or replace an
extension-owned tool/provider.

**Extension processes.** `ExtensionAPI.start_child(api, child_spec)` gives extensions a supervised
home for long-lived processes (watchers, pollers, client connections): each owner gets its own
`DynamicSupervisor` (started on demand under `Catalyst.Extensions.ProcessSupervisor`, registered by
`ext_id` in `Catalyst.Extensions.ProcessRegistry`), so purging/reloading the extension terminates
its **whole subtree** — including children the per-owner supervisor restarted in the meantime.

**Loader.** `Catalyst.Extensions` (ETS live registry) loads `.ex` files from
`~/.catalyst/extensions/`: compile → classify each module (`setup/1`-exporting extension vs
tool-shaped) → **purge previous registrations by `ext_id`** (idempotent reload) → commit. It
compiles **before registry purge/commit**. Every accepted load retains its exact emitted BEAM
binaries in an owner/version stack. If a later compile fails partway, or its contribution is
rejected, those accepted binaries are restored and newly introduced partial modules are removed;
the edited broken source is never used as the rollback source. Purging also undoes **module
definitions**: every module the owner's file compiled is tracked, the next accepted extension
version is restored when owners overlap, and a shadowed application module falls back to its
original code-path beam. Thus a broken file registers nothing new and cannot leave a partially
compiled definition live.
`Catalyst.Extensions.Versioning` `git init`s the dir and commits each successful install
(scoped to the installed file, so unrelated dirty edits stay out of the commit), so
`rollback_extension` is a `git revert` + reload. Loads, installs, reload/disable/enable and
`uninstall` all serialize on one per-process-requester `:global` load lock; the installer's
whole write → load → commit runs as a single critical section (`Extensions.locked/1`).

**Crash-safe boot (`Catalyst.Extensions.BootGuard`).** `CATALYST_SAFE_MODE=1` skips loading
manually; the boot marker makes it **automatic**: a marker file is set to `booting` before
`load_all` and flipped to `ok` after a stabilization window (default 10s). A boot that finds a
stale `booting` marker knows the previous boot died with extensions active, skips loading, and
reports `{:safe_mode, :crash_detected}` via `Extensions.boot_status/0` (surfaced as a banner in
`ShellLive`) — so a bricking extension is recovered by a plain relaunch, no terminal needed. The
state is sticky until an explicit, successful `reload_extensions` marks the boot `ok`. A boot
load/preflight failure is recorded as `{:load_failed, reason}`, logged, shown in the extensions
panel, and deliberately leaves the marker armed; it is never silently marked clean.

**The loop and the system prompt are data.** `Session.RunConfig.resolve_loop/1` picks the loop
module per run (session `opts[:loop]` → `:agent_loop` app env → `Catalyst.Agent.Loop`), and
`Catalyst.SystemPrompt.get/0` resolves the system prompt per run (session override →
`~/.catalyst/system_prompt.md` → built-in default). Both are live on the next run and reverted by
deleting the env/file — the two most identity-defining knobs need no module redefinition at all.

**Hook points (`Catalyst.Hooks`, ETS bag).** Six PI-style points, wired into `agent/loop.ex` +
`tool_runner.ex`, **no-op when empty**. Decision/filter handlers run in isolated supervised tasks
with a deadline. Read-only observers are delivered by `ObserverDispatcher`: one directly
supervised callback process at a time per session, ordered within a session and concurrent across
sessions. A crashing or hanging callback is logged, killed, and skipped. Per-session admission is
bounded; streamed `MessageUpdate`/`ToolExecutionUpdate` events may be dropped at saturation, while
structural events evict an older queued update or apply backpressure, so `MessageEnd`/`AgentEnd`
cannot disappear. Admission and enqueue are one GenServer call, eliminating leaked pre-cast
reservations. The ETS handler table lives in a separate `TableOwner` process inside a
`:rest_for_one` group, so a registry crash restores rather than silently emptying the hooks:

| Point | Where | Power |
|---|---|---|
| `transform_context` | before converting `context.messages` | rewrite/compact/redact context |
| `before_tool_call` | between tool fetch and execute | `{:block, reason}` → error result, tool not run |
| `after_tool_call` | after execute, before `ToolExecutionEnd` | rewrite the result tuple |
| `prepare_next_turn` | after `TurnEnd` (every turn, incl. the natural stop) | return `%{context, config}` for the next turn |
| `should_stop_after_turn` | after every turn | force-stop the loop AND skip the follow-up queue |
| `on` / `notify` | `emit` wrapper at `run/4` | ordered bounded read-only observers; stream updates are lossy under overload, lifecycle events are preserved |

**Registries that resolve live.** `Catalyst.LLM.Registry` (§6) for providers;
`CatalystWeb.UI.Registry` for **pages / renderers / components / commands**.
`CatalystWeb.UI.MessageRenderer` dispatches transcript rendering to registered renderers
(newest-first, `match_fun`) falling back to built-ins. Routing is **catch-all**: one
`CatalystWeb.ShellLive` is mounted at `/` and `/:page` (router ships this once), and
`handle_params` resolves the page registry by path — so a new page (`/settings`) is a registry
write, no router recompile. The chat itself is just a registered page (`Pages.ChatPage`), and
the commands registry is dogfooded the same way: `/cd` is a seeded built-in command, and every
`/name [arg]` chat message dispatches through `UI.Registry.fetch_command/1` (crash-isolated
handlers; unknown names flash the known list).

**Apply-cost matrix.** new tool/provider/hook/renderer/page/panel → registry write (live, next
turn/render); system prompt → write `~/.catalyst/system_prompt.md` (next run); agent loop →
`:agent_loop` app env (next run); background process → `start_child` (immediate, purged with its
owner); markup/layout change → hot-swap + reload (`reload_ui`); CSS/Tailwind or new JS
hook → `CatalystWeb.Assets.rebuild/0` (runs the bundled tailwind+esbuild, §8) then a webview
reload broadcast over the `"ui"` PubSub topic.

**Self-modification tools** (all routed through the loader): `develop_tool` (write+load a tool),
`install_extension` (write+load any module — tool, provider, hook, or UI), `reload_extensions`
(purge+reload by owner), `rollback_extension` (git revert + reload; optional `name` scopes the
LIFO walk to one extension's file via `Versioning.rollback_file/2`); web boot registers
`rebuild_assets` and `reconnect_ui`. The agent is pointed at `./guide.md` (published to
`Catalyst.Paths.join("guide.md")` on boot, `~/.catalyst/guide.md` by default) which documents all
of this relative to the live bundled app.

**Extensions panel (human-facing recovery + introspection).** `/extensions` is a second seeded
built-in page (`Pages.ExtensionsPage`, registered exactly like `Pages.ChatPage`, so it also
dogfoods the page registry). It renders a data snapshot (`panel_data/0`, rebuilt by `ShellLive`
on navigation, after each action, and at `AgentEnd`) of: loaded extensions
(`Extensions.list_loaded/0` — owner/file/tools/modules + process count), disabled extensions
(`Extensions.list_disabled/0`), boot status with a "Load extensions now" recovery button, and
every live registry (tools, providers, hooks via `Hooks.handlers/1`, pages/commands and the new
`UI.Registry.list_renderers/0`/`list_components/0`). Per-extension buttons: **reload**
(`Extensions.reload/1`), **roll back** (`Versioning.rollback_file/2` + `load_all`), **disable** /
**enable** (`Extensions.disable/1` renames the source to `.ex.disabled` under the load lock and
purges the owner — skipped by `load_all` and at boot; `enable/1` renames back and loads; both
renames are committed so rollback history stays coherent). Actions run in supervised tasks
(`ShellLive` `ext_*` events, one at a time, results via `handle_info`), so a slow compile or git
never blocks the LiveView. The safe-mode banner links here — a bricked extension is now
recoverable end-to-end without a terminal. (Patching between pages also replays the chat
transcript from the session snapshot on return — stream items live only in the DOM the other
page replaced.) Files loaded explicitly from outside the configured extensions directory are
shown as **external source** and are reload-only: disable and rollback are hidden, and the core
API rejects disable instead of renaming a file that `list_disabled/0` could never recover.

---

## 12. Debug logging

`Catalyst.Debug` writes a per-session log at `~/.catalyst/debug/<id>.log` (plus a `latest.log`
symlink to the most recent session). It captures structural/final agent-loop events (streaming
deltas are intentionally skipped), each **tool call + result**, and the **truncated Codex request
(+byte size) / response / error** — written from
`Session.Server` (per event; full reason on failure) and the `OpenAICodex.Provider`. Toggle with
`CATALYST_DEBUG=0`. Log/tool text is scrubbed to valid UTF-8 after byte bounds are applied, and a
deleted cached debug directory is revalidated and recreated on the next write. The `read_log` tool
lets the agent read its own canonical session log, and the system
prompt + guide point at it — so when something fails in the packaged app (a tool call, a stream
close, a TCC `:eperm`), the agent and the developer have the same trail. This log is how the
`Finch.stream/5` 3-tuple transport-close crash (§6 caveat) was found and fixed.

See `plan.md` for the phased delivery sequence, exit criteria, and risks.
