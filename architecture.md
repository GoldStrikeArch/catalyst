# Catalyst — Architecture

Catalyst is an Elixir/OTP reimplementation of **PI** (a minimal coding-agent harness,
originally TypeScript — see `./tmp_pi`), delivered as a **native desktop GUI** via
[`elixir-desktop/desktop`](https://github.com/elixir-desktop/desktop) (wxWidgets + Phoenix
LiveView). It keeps PI's minimal agent surface but swaps in fast Rust tools and adds
structural code editing, request-time context safety, and supervised child sessions:

- **ripgrep** for grep, **fd** for find, **sd** for sed, **ast-grep** (tree-sitter) for
  structural/AST code edits.
- A pluggable LLM provider layer, **starting with OpenAI Codex (ChatGPT subscription,
  OAuth)**, designed to grow toward PI's full provider breadth.

> Toolchain status on the dev machine (verified): Erlang/OTP 29, Elixir 1.20, `:wx`
> **available**, and `rg`/`fd`/`sd`/`ast-grep` all installed.

**Beyond PI parity — "modify everything at runtime."** Catalyst leans on BEAM hot code loading
to make the running app self-modifiable: _everything is a registry + hooks + hot-swap._ Tools,
LLM providers, purpose-aware prompts, workflows, context policy, agent-loop hooks, and the UI
(pages, renderers, panels, CSS/JS) are each an
ETS-backed registry — most seeded from built-ins at boot, while the prompt/workflow/context
registries hold runtime overlays over live application/file/built-in fallbacks (§11) — writable
at runtime through one unified `Catalyst.ExtensionAPI`. The agent compiles and loads new modules into the live VM (the Elixir
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
        tasks.ex paths.ex ids.ex owned_index.ex    # shared task, path, id, and ownership helpers
        files/atomic_write.ex                      # shared atomic replacement + mode preservation
        agent/{event.ex, loop.ex, tool_runner.ex, children.ex, children/table_owner.ex}
        hooks.ex hooks/{table_owner.ex, observer_dispatcher.ex}
                                                   # hook registry + ordered bounded event observers (§11)
        system_prompt.ex prompt.ex prompt/{request.ex,resolution.ex,config.ex,registry.ex}
                                                   # purpose/model-aware prompt resolution (§11)
        workflow.ex workflow/{registry.ex,support.ex}
        context/{policy.ex,registry.ex,tokens.ex,window.ex,guard.ex,compaction.ex,
                 transcript.ex,summarizer.ex}      # request guard + persistent compaction (§4/§9)
        extension.ex extension_api.ex              # extension behaviour + unified API (§11)
        extensions.ex                              # stable public facade + registered process name (§11)
        extensions/{server.ex, load.ex, presenter.ex,
                    versioning.ex, boot_guard.ex, processes.ex, state.ex,
                    contribution.ex, owner.ex,
                    transaction.ex, module_versions.ex, sources.ex,
                    installer.ex, loader.ex, compiler_tracer.ex}
                                                   # git versioning + crash-safe boot + isolated loading
                                                   # + shared write→load→commit pipeline w/ self-mod kill switch (§11)
        debug.ex                                   # per-session debug log (§12)
        session/{server.ex, manager.ex, store.ex, event_sink.ex,
                 reducer.ex, run_config.ex, run_context.ex, snapshot.ex,
                 catalog.ex, server/state.ex, store/codec.ex}
                                                   # thin server + extracted state/codec + hot-swap logic
                                                   # + persisted {id, cwd, title} session catalog
        tools/{tool.ex, registry.ex, exec.ex, binaries.ex, truncate.ex, listing.ex, paths.ex,
               diff.ex,
               context.ex, read.ex, write.ex, edit.ex, ls.ex, bash.ex,
               ripgrep.ex, fd.ex, sd.ex, ast_grep.ex,
               develop_tool.ex, install_extension.ex, reload_tool.ex,
               rollback_tool.ex, read_log.ex, list_agents.ex, spawn_agent.ex,
               self_mod_report.ex}
                                                   # …+ self-modification and child-session tools (§5/§11)
        llm/{provider.ex, provider_config.ex, registry.ex, event.ex, context.ex,
             sse.ex, faux.ex, openai_codex.ex,
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
        live/shell_live/{chat_input.ex, commands.ex, conversation.ex,
                         extension_actions.ex, run_diagnostics.ex,
                         session_lifecycle.ex, settings.ex, threads.ex}
                                                   # extracted ShellLive concerns
        pages/chat_page.ex                         # the chat as a registry-registered page
        pages/extensions_page.ex                   # extensions/settings panel (also a seeded page, §11)
        ui/{registry.ex, table_owner.ex, contributions.ex, message_renderer.ex,
            page_renderer.ex, markdown.ex, safe_render.ex}
                                                   # pages/renderers/components/commands + replay log (§11)
        tools/{rebuild_assets.ex, reload_ui.ex}    # web-side self-mod tools (§11)
        components/* controllers/*
    catalyst_desktop/          # Desktop.Window child + release/packaging (depends on web)
      lib/catalyst_desktop.ex
    catalyst_cli/              # headless (no-wx) release — proves packaged hot-loading
      lib/catalyst_cli.ex
  rel/macos/launcher.c         # native arm64 .app launcher (§8)
  config/{config.exs, dev.exs, prod.exs, runtime.exs, test.exs}
```

The boundary is enforced by app dependencies: `catalyst` carries no Phoenix; `catalyst_web`
depends on `catalyst`; `catalyst_desktop` depends on `catalyst_web`. This keeps the agent
core runnable headless (iex/escript/tests) and lets the LLM core be extracted later. The core
never references `catalyst_web` directly — UI extension _kinds_ are dispatched through
`:persistent_term` (§11) so the dependency arrow only ever points web → core.

---

## 3. Supervision tree

```
Catalyst.Application (top, in apps/catalyst)
├── {Phoenix.PubSub, name: Catalyst.PubSub}
├── {Finch, name: Catalyst.Finch}                 # SSE streaming + token HTTP
├── {Task.Supervisor, name: Catalyst.TaskSupervisor}        # run, hook, metadata, refresh tasks
├── Catalyst.Hooks.ObserverDispatcher             # ordered, bounded async event observers — deliberately
│                                                 #   OUTSIDE the extension group: observer entries are passed
│                                                 #   by value, so admitted queues survive registry recovery
├── Catalyst.Tools.Registry                     # validated, fingerprinted tool-definition cache
├── Catalyst.Auth.TokenStore                      # GenServer, single-flight token refresh
├── Catalyst.LLM.OpenAICodex.CatalogCache         # live model metadata, single-flight refresh
├── Catalyst.LLM.OpenAICodex.ConnCache            # idle Codex ws conns between runs (delta-upload state, §6)
├── ExtensionRuntimeSupervisor (:rest_for_one)    # order load-bearing: a crash restarts everything
│   │                                             #   after it; max_restarts test-overridable
│   ├── Catalyst.Hooks.TableOwner                 # owns the hooks ETS table (handlers survive a Hooks crash)
│   ├── Catalyst.Hooks                            # ETS agent-loop hook registry (§11)
│   ├── Catalyst.LLM.Registry                     # ETS provider registry: built-ins + runtime (§11)
│   ├── Catalyst.Prompt.Registry                  # purpose/model prompt + policy runtime overlay (§11)
│   ├── Catalyst.Workflow.Registry                # named/default workflow runtime overlay (§11)
│   ├── Catalyst.Context.Registry                 # policy + threshold runtime overlay (§4/§11)
│   ├── {Registry, keys: :unique, name: Catalyst.Extensions.ProcessRegistry}  # owner -> ext supervisor (§11)
│   ├── {DynamicSupervisor, name: Catalyst.Extensions.ProcessSupervisor}      # extension-owned processes (§11)
│   └── Catalyst.Extensions                       # last: its load_all re-registers into the ones above (§11)
├── {Registry, keys: :unique, name: Catalyst.Session.Registry}
├── AgentChildrenSupervisor (:rest_for_one)
│   ├── Catalyst.Agent.Children.TableOwner          # lease/index ETS survives coordinator restarts
│   └── Catalyst.Agent.Children                     # root-tree leases + rebuilt process monitors (§5)
└── {DynamicSupervisor, name: Catalyst.Session.DynamicSupervisor}   # one Session.Server per session
                                                  # (outside the group: sessions ride out a registry restart)

CatalystWeb.Application (in catalyst_web — :rest_for_one, max_restarts test-overridable)
├── CatalystWeb.UI.Contributions                   # replay log of exact accepted UI contributions; first so
│                                                  #   rest-for-one table recovery keeps it
├── CatalystWeb.UI.TableOwner                      # owns the UI ETS table independently of the registry process
├── CatalystWeb.UI.Registry                        # UI registry: pages/renderers/components/commands (§11)
└── CatalystWeb.Endpoint                           # + register_web_tools/0 after boot (rebuild_assets/reload_ui,
                                                   #   registered as an Extensions reseeder so restarts re-add them)

Catalyst.Desktop (Desktop.Window child)           # started by catalyst_desktop, desktop mode only

# per session: Session.Manager starts a Catalyst.Session.Server (GenServer, PI Agent analog)
# directly under Catalyst.Session.DynamicSupervisor; the run (loop) Task runs under the shared
# Catalyst.TaskSupervisor, and tool Tasks are Task.async_stream children linked to that run
# Task (abort = kill the run Task; the linked tool Tasks + their Ports die — a deliberate
# abort cascade, not a shared tool-task supervisor).
```

The extension group, including the provider, prompt, workflow, and context registries, boots
**before** any session so the very first turn sees built-ins. These registries hold only the
owner-aware runtime overlay in ETS; their resolvers read application/file/built-in layers live.
They start after `LLM.Registry` and before `Catalyst.Extensions`, so an extension reload can purge
and rebuild all contributions coherently (§11).

---

## 4. Process model (maps directly onto PI)

- **`Session.Server`** = PI's `Agent`: the single writer of transcript / model / queues /
  pending state. API: `prompt/2`, `continue/1`, `steer/2`, `follow_up/2`, `abort/1`,
  `state/1`, `reset/1`. "Subscribe" = the caller subscribes to PubSub topic `"session:<id>"`.
  The server is deliberately **thin**: event fold/reduce (`Session.Reducer`), host-side run
  preflight/configuration (`Session.RunConfig`), worker-side run construction
  (`Session.RunContext`), and snapshotting for late joiners (`Session.Snapshot`) live in stateless,
  hot-swappable modules it delegates to — so deep behavior changes are module reloads, not session
  restarts. The struct definition lives in `Session.Server.State`; the
  queues and state ownership remain in the GenServer callbacks (additive `%State{}` fields are
  free; destructive changes need `code_change/3` or a rebuild-from-JSONL).
- **`Agent.Loop.run(prompts, context, config, emit)`** = `agent-loop.ts` and implements
  `Catalyst.Workflow`: a plain recursive
  function run through `Catalyst.Tasks.async/1` under the shared task supervisor. `emit` casts
  a run-ref-scoped `{:agent_event, ...}`
  to `Session.Server`, which folds it into state (like `processEvents`), persists on
  `message_end`, and `Phoenix.PubSub.broadcast`s it to subscribers. The loop calls back into
  `Session.Server` for queue draining and the tool hooks. PI-parity semantics worth naming:
  steering is re-checked after **every** turn (a steer landing during the final toolless turn
  runs another turn instead of sitting queued); a tool batch terminates the loop only when
  **every** call asked to; a provider error/abort ends the run immediately **without**
  draining follow-ups; `prepare_next_turn`/`should_stop_after_turn` run after every turn, and
  a `should_stop` veto also skips the follow-up queue. It uses `Workflow.Support` for observed
  emission, live tool/capability resolution, and guarded provider requests. (There is no
  `get_api_key` config —
  the Codex provider fetches a fresh token per attempt from `Auth.TokenStore` itself.)
- **Cancellation = process kill** (no AbortSignal): `abort` kills the run Task; linked tool
  tasks die; their linked Ports / MuonTrap daemons kill the OS process group. On an abnormal
  `:DOWN`, `Session.Server` synthesizes an aborted/error Assistant turn (PI's
  `handleRunFailure`). A `spawn_agent` watchdog separately monitors the tool task and stops its
  child session when that owner dies; `Session.Server.terminate/2` never synchronously cascades
  through the shared `DynamicSupervisor`.
- **`ToolRunner`**: sequential vs parallel batch (parity with PI — any tool with
  `execution_mode: :sequential`, or a config flag, forces sequential). Validates args against
  the tool's JSON schema (`ex_json_schema`), runs each tool in a `Task.async_stream` Task
  linked to the run Task (so an abort cascades); a crash
  becomes an error tool-result (the "thrown becomes error result" rule). The `onUpdate`
  callback is a closure (`ctx.report`) that emits `ToolExecutionUpdate`; `bash` streams a
  bounded output tail through it, throttled in-tool to one report per 100ms.

### Run boundary and request-time context guard

`Session.Server` performs only host-owned acceptance checks synchronously (`:busy`, missing
provider, unknown API), snapshots state, then starts a supervised run task. Inside that task,
`Session.RunContext` resolves the effective catalog/model metadata, prompt, and workflow. Prompt
or workflow extension callbacks therefore cannot block or crash the session GenServer. The
resolution is pinned as run data and reported with the run reference: prompt text/digest/ordered
sources, workflow name/module/source, and model context metadata. `current_run_metadata` is
promoted to `last_successful_run_metadata` only after a normal `AgentEnd` whose final assistant is
neither error nor aborted; stale, failed, reset, and aborted run metadata is discarded. Snapshots
expose current metadata during a run and the last successful metadata otherwise, but never reuse
it as future configuration.

Before every ordinary provider request, a conforming workflow calls
`Context.Guard.prepare_request/4`. The guard applies `transform_context` once, constructs the exact
provider context (instructions, transformed messages, and current tool schemas), fingerprints and
estimates it, resolves the context policy/threshold, and emits transient `ContextStatus`. If the
request meets the threshold, it stages a policy-supplied chronological replacement, applies the
transform once more to that candidate, and accepts it only after transcript validation, strict
token progress, and a below-threshold re-estimate. Only then does it emit durable
`ContextCompacted`. `Session.EventSink` synchronously appends it before the session folds or
broadcasts the replacement, then hands the committed notification to ordered observer delivery;
observer callbacks remain outside the Session GenServer. An append failure leaves both live and
restored transcripts unchanged and aborts the provider request. A rejected candidate changes
nothing. Internal summarizer requests bypass recursive guarding.

`Context.Tokens` uses optional provider `context_fingerprint/3` and `estimate_tokens/3` adapters;
otherwise it uses a deterministic provider-neutral SHA-256 projection and a conservative coarse
estimate. `OpenAICodex.Request` owns both the Codex wire encoder and its stable semantic projection:
the latter reuses the same message/tool conversion while omitting only generated assistant replay
ids and normalizing JSON-equivalent schemas/arguments. A successful assistant usage total becomes
an anchor only when a provider fingerprint adapter produced its digest and that digest still
matches the current semantic prefix. A fallback digest remains useful for change detection but is
never an anchor. Status therefore explicitly distinguishes provider/coarse and anchored/unanchored
accounting.

`Context.Window` resolves the policy runtime overlay → current `:context_policy` → built-in, and
its threshold in this order: session `context_threshold`; runtime exact model id/API/`:default`;
current `:context_thresholds` for those keys; then the lower of a valid catalog auto-compact limit
and 85% of the usable window when anchored or 70% when unanchored. A positive integer is absolute,
a ratio in `(0, 1]` is applied to the effective window, and `:none` explicitly disables Catalyst
compaction (not the provider's hard limit). An absolute value above the usable window or a ratio
without one is a tagged configuration error.

### Parent and child session topology

`list_agents` discovers validated markdown definitions under `~/.catalyst/agents/` on every call.
`spawn_agent` reserves a root-tree lease in `Catalyst.Agent.Children`, exclusively creates a real
child `Session.Server`, subscribes before prompting, and waits for its `AgentEnd`. The child has a
fresh transcript and continuation, but inherits the parent's cwd, model, provider, sanitized run
options, workflow, live `tool_source`, global hooks/permissions, root id, and incremented depth.
It does not inherit messages or isolate the filesystem.

```
root Session.Server (root_session_id = own id, depth 0)
├── child Session.Server (parent_id = root, same root id, depth 1)
│   └── grandchild Session.Server (parent_id = child, same root id, depth 2)
└── child Session.Server (parent_id = root, same root id, depth 1)
```

The root-wide lease count prevents fan-out limits from resetting at each depth. The final
capability filter removes `SpawnAgent` at the configured depth even from extension or explicit
tool sources. A supervised watchdog acts as each lease's cleanup keeper: caller death or startup
timeout leaves capacity reserved until any in-flight child creation has completed and the child is
stopped. The independently owned ETS table lets `Agent.Children` reconstruct those live leases and
monitors after a coordinator restart. Child IDs use the parent plus a random 128-bit suffix;
exclusive manager/store creation retries collisions without adopting an existing process or
transcript. Normal completion stops the live child and preserves its JSONL; owner death, timeout,
provider failure, abort, or a premature child exit is a tool error and triggers cleanup.

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
`MessageUpdate`s ≤ the snapshot), so no event is lost or doubled around the reattach.
Attach resolution is two-tier: a warm VM reuses the `:persistent_term` session memo; after a
full VM restart the GUI consults the core-owned persisted catalog (`Catalyst.Session.Catalog`,
`~/.catalyst/session_catalog.json`, `{id, cwd}` entries pruned against the on-disk stores) and
reopens the most recent session's JSONL through the normal `load_state` replay. Default cwd
policy is shared: both core and web resolve through `Catalyst.Paths.default_cwd/0`
(process cwd → user home; releases skip the process cwd). The
message list uses LiveView `stream/3`. **Streaming renders live with block-commit markdown**
(the Codex CLI's strategy adapted to LiveView): each text/thinking delta is `push_event`ed to
a client-side `StreamingMessage` hook that appends into a `phx-update="ignore"` raw tail; on
newline-carrying deltas the server re-parses the accumulated text with
`UI.Markdown.stable_split/1` — every block except the last is **stable** (newline gating +
line-anchored classification make commits monotone; a trailing fence-closed code block
commits immediately) — and newly stabilized blocks render ONCE through the real
`MessageRenderer` into a per-message stream inside the bubble. Complete tail lines
paint through `preview_tail/1` as markdown (so an open list is already a list);
a `stream_tail` event trims the ignored raw region to the unfinished last line. Fenced code gets **syntax highlighting**
(vendored highlight.js via the `Highlight` hook — explicit fence language only, input via
`textContent`) the moment its fence closes, and the `message_end` swap to the final message
renders the same blocks through the same pipeline — visually a no-op. A late joiner seeds
committed blocks + tail from the snapshot's `streaming_message`. Tool spinners show a live
output tail streamed by `bash` via `ToolExecutionUpdate`. A composer **Quiet** toggle
(display-only, persisted in its own persistent_term separate from the Codex prefs) sets
`data-quiet` on the transcript container; CSS rules in `app.css` then hide tool chips,
tool-result cards, and thinking — CSS rather than re-render because stream/ignore regions
never re-render on assign changes. Spinners stay visible; the session is never touched.
`ContextCompacted` resets and re-streams the replacement transcript; `ContextStatus` updates
footer context diagnostics without adding a chat block. The footer shows used tokens,
effective threshold/source, anchored versus estimated state, and read-only prompt
text/digest/provenance from the current or last-successful run. A toggleable sidebar lists
**projects** (unique `cwd`s) and **threads** (`Session.Server`s). New/switch never stop
sibling sessions; close stops the process and drops the catalog entry.

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
  # ctx is Catalyst.Tools.Context: cwd, parent/root ids, model/provider, inheritable opts,
  # workflow, original tool_source, depth, call_id, and report; raise -> error tool-result
end
```

`Catalyst.Tools.Exec` wraps two shell-out modes:

- **`collect/3`** — plain `Port` `{:spawn_executable, ...}`, accumulate stdout, parse after
  exit, receive-after timeout. Used by the single-shot structured tools.
- **`bash/2`** — the muontrap wrapper binary for reliable process-group SIGKILL + timeout.
  A dedicated supervised task exclusively owns the linked Port and relays one chunk at a time;
  accumulation and the crash-isolated `:on_output` callback stay in the caller. Timeout, output
  cap, callback failure, and caller failure all stop and fence that owner before returning.
  `bash` uses the callback to stream a throttled partial-output tail through `ctx.report`.

`Catalyst.Tools.Binaries` resolves `rg`/`fd`/`ast-grep`/`sd` from `~/.catalyst/bin`, the
bundled `priv/bin` (packaged app), `PATH`, then Homebrew paths (cached in
`:persistent_term`). Per-OS/arch **auto-download** à la PI's `ensureTool` is deferred —
today a missing binary raises with an install hint.

`Catalyst.Tools.Registry` validates a tool's name/description/schema once at registration and
caches the result under the module's BEAM fingerprint. Turn assembly reads that cache; a hot-code
change invalidates the fingerprint and forces one bounded revalidation, rather than spawning a
task for every tool on every turn. Each entry keeps the module, validated definition and execution
mode, resolved schema, and (for `use Catalyst.Tools.Tool`) a local executor capture pinned to the
same BEAM generation. `Workflow.Support.resolve_turn_tools/1` builds one tool index
(`Registry.index/1`) from those entries at the start of each turn, and
`ToolRunner.run_batch_with_index/4` executes the whole batch from that index — so `ToolRunner`
never re-enters extension metadata callbacks and cannot execute replacement code under an older
schema/mode snapshot, per entry **and** per turn. A stale legacy tool without
a pinnable executor returns a tagged error result instead of calling the new generation. Invalid
metadata is logged and the tool is omitted.

`Catalyst.Agent.ToolRunner` validates each call's args against the tool's declared JSON
Schema (`ex_json_schema`) before executing — a malformed call (most common with
self-developed tools) becomes a clean error tool-result the model can correct, not a
crash inside `execute/2`. An unresolvable schema skips validation rather than blocking.

| Tool                                                                                   | Backend                                   | Notes                                                                                                                                                                                                                                  |
| -------------------------------------------------------------------------------------- | ----------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `read` `write` `ls`                                                                    | pure Elixir `File`                        | line offset/limit, truncate 2000/50KB; image files (jpg/png/gif/webp by magic bytes) return base64+mime content blocks (≤5MB; no resizing)                                                                                             |
| `edit`                                                                                 | pure Elixir                               | oldText/newText exact replace with PI's **fuzzy fallback** (NFKC + trailing-whitespace/smart-quote/dash/space normalization; any fuzzy edit rewrites the file in normalized space), unified diff (`Tools.Diff`) in content + `details` |
| `bash`                                                                                 | MuonTrap                                  | `bash -c` (fallback `sh -c`; no `-l` — no login-profile sourcing), tail-truncate, 100ms-throttled live output tail via `ctx.report` (temp-file spill deferred)                                                                         |
| `grep`                                                                                 | ripgrep `collect`                         | `rg --json --line-number --color=never --hidden [flags] -- PATTERN PATH`; parse `type:"match"`; cap at limit                                                                                                                           |
| `find`                                                                                 | fd `collect`                              | `fd --color never [--hidden] [--glob] PATTERN PATH`                                                                                                                                                                                    |
| `replace`                                                                              | sd `collect`                              | `sd [--string-mode] PATTERN REPL FILE…`; unified diff (pre/post read) in content + `details`                                                                                                                                           |
| `ast_grep`                                                                             | ast-grep `collect`                        | search: `ast-grep run --pattern P --lang L --json=stream PATH`; rewrite: add `--rewrite R --update-all`. Two sub-actions chosen by presence of a `rewrite` arg. Resolve the binary as `ast-grep` (not `sg`).                           |
| `list_agents` `spawn_agent`                                                            | `Agent.Children` + real `Session.Server`s | discover fresh file-backed agent prompts; run a named agent in an exclusively-created child session with root-wide depth/fan-out limits; return bounded final text flagged `untrusted` in structured details (harness metadata, not a provider-visible envelope)                                               |
| `develop_tool` `install_extension` `reload_extensions` `rollback_extension` `read_log` | `Catalyst.Extensions` / `Debug`           | **self-modification tools** (§11/§12): write+load a tool or any extension module, reload/rollback the extensions dir, read this session's debug log. Web boot also registers `rebuild_assets` + `reload_ui`.                           |

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
testable with no network — built before the real provider. `Catalyst.LLM.Demo` (test-only,
`apps/catalyst/test/support/`) is an offline, input-aware provider (runs a real
`ls`/`grep`/`find` then word-streams a reply) with **no UI surface**: the app's only real
provider is Codex; the LiveView test helper overrides the Codex API through
`Catalyst.LLM.Registry` to drive full turns offline.

Providers are resolved through **`Catalyst.LLM.Registry`** (ETS-GenServer), keyed by `api` name
and seeded with the built-ins (`faux`, `openai-codex-responses`). A session resolves its provider
by module or by api-name; new providers are added at runtime with
`register_provider(api, %Catalyst.LLM.ProviderConfig{…})` (or a bare module), and recompiling a
provider module changes behavior on the next `stream/4` with no restart (§11).

**`Catalyst.LLM.OpenAICodex`** (verified against PI source + the Codex CLI, `openai/codex`):

- URL `https://chatgpt.com/backend-api/codex/responses`.
- **Model catalog** (`OpenAICodex.list_models/0`): `config :catalyst, :codex_models` override
  wins; otherwise the GPT-5.6 Sol/Terra/Luna entries are pinned first, followed by the **live
  list** from `GET <base>/codex/models?client_version=…` (fetched in a background task when
  authenticated, 5-min TTL, `visibility: "list"` models sorted by priority, Fast from
  `service_tiers`, efforts from `supported_reasoning_levels`; disabled by
  `:codex_live_models, false` — set in test). A duplicate live GPT-5.6 entry supplies live
  metadata without changing the trio's order or known Fast support. Freshness follows the CLI's
  **`x-models-etag`** signal: every /responses response (SSE headers and the ws upgrade) is
  checked — a matching etag just renews the cache TTL, a new one forces a background refetch.
  When no live entries are cached, the complete bundled list is used —
  gpt-5.6-sol / gpt-5.6-terra / gpt-5.6-luna, then gpt-5.5 / gpt-5.4 /
  gpt-5.4-mini / gpt-5.3-codex / gpt-5.2. The three GPT-5.6 models are Fast-capable and use
  Codex's 272,000-token working window; Sol/Terra support low/medium/high/xhigh/max/ultra,
  Luna supports low/medium/high/xhigh/max, and their defaults are low/medium/medium.
  Older entries support low/medium/high/xhigh (default medium). All are vision-capable
  (`input: [:text, :image]`). A custom `:codex_model` id is always included. The toolbar reads
  models plus defaults through one consistent
  `catalog_snapshot/0` call rather than several serialized cache calls per render; a selected
  id missing from the effective catalog (for example an unpinned bundled model selected before
  a live refresh, or an explicit override omission) is appended as a bare entry so the model
  `<select>` always contains its value.
  Catalog entries carry `context_window`, `max_context_window`,
  `effective_context_window_percent`, and `auto_compact_token_limit`. `RunContext` takes one
  effective catalog snapshot at run start (configured models → pinned GPT-5.6 plus live cache →
  bundled fallback) so a mid-run refresh cannot mix limits. An explicit session window remains
  source `:session`;
  otherwise a matching catalog entry refreshes legacy/persisted metadata, falling back to the
  persisted values or Codex's 272,000-token default. `Store.Codec` persists the normalized fields
  and `context_window_source`; it does not persist a live catalog object. Thus a catalog refresh
  changes the next eligible run, while a deliberately fixed session override stays fixed.
- **Run options** (session opts, set live from the composer bar via `Session.Server.configure/2`,
  applied on the next run): `:reasoning_effort`, `:service_tier` (`"priority"` = **Fast mode**,
  ~1.5x speed / increased usage, the GPT-5.6 family plus gpt-5.5 and gpt-5.4), `:transport`.
  `:session_id` is reserved:
  `Session.Server` strips nested caller values and `RunConfig` always installs the validated
  `state.id`, so cache/header/debug/tool identities cannot diverge.
- **Transports** (`opts[:transport]` | `config :catalyst, :codex_transport`, default `:auto`):
  `:websocket` — the CLI's preferred transport (`Catalyst.LLM.OpenAICodex.WebSocket`,
  Mint + mint_web_socket): upgrade on the same path with
  `OpenAI-Beta: responses_websockets=2026-02-06`, ONE `{"type":"response.create", ...body}` text
  frame per turn, Responses events back as JSON text frames, pings answered with pongs, and
  idle/connect timeouts. `OpenAICodex.ResponseEvent` is the shared normalization/termination
  policy: legacy `response.done` becomes `response.completed`, and completed, incomplete, failed,
  cancelled, and error events all end the receive loop without waiting for the ten-minute idle
  deadline. Between requests the
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
- `StreamParser` normalizes through `ResponseEvent`, then maps Responses events →
  `Catalyst.LLM.Event` (port
  `openai-responses-shared.ts`): `response.output_text.delta` → TextDelta; reasoning deltas →
  ThinkingDelta; `function_call` item add / `arguments.delta` / done → ToolCall
  start/delta/end; `response.completed` → Done (fill usage, set `:tool_use` if tool calls);
  `response.failed`/`error` → Error (`error` accepts both the SSE top-level and the
  websocket nested `{"error": %{...}, "status": ...}` shapes, never finalizing blank).
  Reasoning item id + `reasoning.encrypted_content` are round-tripped on the next request;
  replay strips the stream-position fields (`output_index`, `sequence_number`) a websocket
  stream attaches to the stored item — the backend 400s on replayed `output_index`.
  Retry/usage-limit parsing ported from `parseErrorResponse`.

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

The desktop release runs custom steps after `:assemble` so the **packaged** app can self-modify.
A deterministic `release_preflight!` step runs before the bundling steps and **fails loudly**,
listing every missing packaging input at once (web app dir, the fast-tool binaries,
esbuild/tailwind) instead of warn-and-skip. Then:

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
markers, durable `compaction` replacements, and authoritative **`settings_snapshot`** entries.
`configure/2` appends one snapshot containing both the current model and thinking level before
installing either live change; a failed append leaves both settings unchanged. `load_state/1`
folds transcript and settings in one pass, accepts legacy `model_change` /
`thinking_level_change` entries, and lets the latest valid snapshot atomically supersede both.
Explicit `nil` values are persisted tombstones, distinct from settings never written, and
transcript resets do not reset settings. `active_tools_change` is still skipped — tools resolve
live per turn.
Append on each `message_end`. A `ContextCompacted` entry stores the complete chronological
replacement; folding it replaces the logical transcript, while later message lines continue from
that state. Append/encoding failures are tagged; ordinary message persistence remains explicitly
best-effort, while compaction is accepted only after a successful append. Reset is authoritative
too: its marker is appended before an active run is stopped or live state is cleared, and a failed
append returns a tagged error while leaving the run and transcript untouched. Persisted message
decoding also returns tagged results rather than using exceptions for line skipping. Malformed
lines, including malformed compactions, leave the prior accumulator intact
and later valid lines still fold. Older builds ignore the unknown entry and replay the physical
pre-compaction messages, a non-destructive but potentially oversized fallback. Rebuild into a
`%Context{}` by folding lines
(port `buildSessionContext`), tolerating corrupt/unknown lines. `Session.Server` calls the
`Store` module directly (a future `ecto_sqlite3` backend means introducing a behaviour then —
it is not behind one today; swapping stores is still just a module hot-swap, §11).

Root and child sessions use the same store. Headers include optional `parentId`,
`rootSessionId`, and `agentDepth`; the exclusive create-new path fails when either a live session
or an on-disk transcript already owns the requested child id. These fields survive resume and keep
the depth capability restriction intact. Run prompt/workflow/context diagnostics and transient
`ContextStatus` are intentionally not JSONL configuration; they repopulate on the next run.

`Catalyst.Paths.home/0` is the shared root for default auth, session, debug, system-prompt,
purpose-aware prompt, file-backed agent, guide, boot-marker, and downloaded-binary paths.
Resolution is explicit app
`config :catalyst, :home` → `CATALYST_HOME` → `~/.catalyst`; the environment variable gives a
packaged release a configuration-free isolation/relocation seam. The narrower `:extensions_dir`
override affects only extension source discovery; it does not silently move credentials or
transcripts. Consumer-specific overrides such as `:auth_path`, `:sessions_root`,
`:system_prompt_path`, `:prompts_dir`, `:agents_dir`, and `:boot_marker_path` still win.

---

## 10. Dependencies

- **Core (`apps/catalyst`):** `phoenix_pubsub`, `finch`, `mint_web_socket` (Codex websocket
  transport), `req`, `jason`, `muontrap`, `ex_json_schema`, `bandit`/`plug` (OAuth callback
  server; also the test websocket server via `websock_adapter`, test-only).
- **Web/desktop:** `phoenix`, `phoenix_live_view`, `bandit`, `desktop`, `esbuild`, `tailwind`;
  packaging via `desktop_deployment` (GUI `.app`) and `burrito` (headless `catalyst_cli`).
- **Later:** `joken` (verified JWT), `ecto_sqlite3`.
- **Note:** runtime extensibility (§11) added **no new deps** — it is plain BEAM hot code loading
  (`Code.compile_file/1` + ETS registries), which is exactly why it works inside the packaged app.

---

## 11. Runtime extensibility (registries + hooks + hot-swap)

_Everything is a registry + hooks + hot-swap._ Extension points use ETS-backed registries, are
written through owner-aware registration APIs (extension setup uses the unified facade), and are
read live on each use. Seeded registries contain their built-ins at boot; the Prompt, Workflow, and
Context registries instead store runtime overlays only and resolve live application/built-in
fallbacks after those overlays.
Above those specialized stores, `Catalyst.Runtime` provides a process-free semantic read model:
versioned service keys/contracts, scoped owner claims, additive contributions, deterministic
resolution explanations, and graph snapshot identities. Core and optional hosts register stable
`{module, function}` read adapters, so `catalyst_web` can contribute UI pages/renderers/components/
commands without introducing a core → web dependency. `Runtime.snapshot/1` reports each source's
health and declared coverage; the built-in read-only `runtime_graph` tool exposes the same graph to
the agent.

The first execution pilot is `agent.run_engine`: `Session.RunContext` resolves it at the run
boundary and records service/owner/provenance/snapshot metadata. Workflow explanations include the
valid runtime → application/ACP → template → configured-loop → built-in chain. Resolution remains
process-free for previews and explanation; an executing managed run upgrades it to a monitored
`Runtime.Handle` with a `:run` lease. Activating a replacement marks the old generation
`:retiring`; its candidate process subtree remains alive until the final lease is released, while
all new runs resolve the new active generation. `runtime_graph` reports active/retiring/retired
generations and their leases. These are lifecycle leases, **not exact-code retention**:
generation-scoped physical modules, drain deadlines, and state handoff remain future work. Raw
trusted BEAM overrides also remain opaque and cannot promise complete graph introspection.

The extension ontology is no longer closed in `Catalyst.ExtensionAPI`. Host subsystems declare
schema-aware `Runtime.ExtensionPoint` values with stable `{module, function}` activation handlers,
while extensions may call `define_extension_point/2`, `contribute/4`, and `claim/4`. Generic
definitions and entries are owner-scoped process-free data; the specialized tool/provider/
workflow/policy/UI registries remain authoritative execution stores. Removing the owner of a point
hides dependent entries without deleting entries owned by other extensions. Reintroducing a
compatible point makes those entries visible again. A generic service claim only changes execution
when its defining subsystem consumes Runtime Graph resolution or supplies a host activation
handler—graph visibility is not presented as execution activation.

The enabler is BEAM hot code loading: behavior lives in plain modules the loop/UI call fresh, so
loading a new version changes behavior on the next call/render — even in the packaged release (the
Elixir compiler ships in it). Self-modification is **auto-allowed**; the safety net is **bounded
compile with exact accepted-BEAM restoration + git versioning + safe-mode boot (manual AND
automatic, see below)** (no approval cards — an approval gate can be added _as an extension_ via
the `before_tool_call` hook). Compilation occurs in the live VM, so it is not a side-effect-free
dry run: emitted modules are immediately installed and must be restored if a later expression in
the file fails.

**Unified API.** `Catalyst.Extension` is a behaviour (`setup(api) :: :ok | {:error, term}`, plus
optional `metadata/0` — merged into `Extensions.list_loaded/0` and shown on the `/extensions`
panel). `Catalyst.ExtensionAPI` is the facade an extension's `setup/1` receives. Its generic
`define_extension_point` / `contribute` / `claim` operations support subsystem-defined ontologies;
the existing typed wrappers remain:
`register_tool` / `register_provider` / `register_prompt` / `register_prompt_policy` /
`register_workflow` / `register_context_policy` / `register_context_threshold` /
`register_hook` / `on` / `register_renderer` / `register_component` / `register_page` /
`register_command` / `start_child`. Each is tagged with the owning file's `ext_id`. Web-only points
(renderers/components/pages/commands) register their own handlers, so **core never depends on
`catalyst_web`**. Direct host registrations use reserved host owners; they may refresh their own
points but cannot detach or replace an extension-owned tool/provider.

**Extension processes.** `ExtensionAPI.start_child(api, child_spec)` gives extensions a supervised
home for long-lived processes (watchers, pollers, client connections): each owner gets its own
`DynamicSupervisor` (started on demand under `Catalyst.Extensions.ProcessSupervisor`, registered by
`ext_id` in `Catalyst.Extensions.ProcessRegistry`), so purging/reloading the extension terminates
its **whole subtree** — including children the per-owner supervisor restarted in the meantime.
Teardown takes nonblocking link snapshots rather than querying a potentially wedged owner
supervisor; graceful termination is bounded, then the owner and extension-child links are killed
without touching the shared Registry partition. This also recovers from a child `start_link`
callback that never returns.

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
Lifecycle calls into the state server share
`config :catalyst, :extension_lifecycle_call_timeout` (default 30s), including direct uninstall
and disable's purge. This is independent of the extension-process tree's shorter graceful
shutdown deadline, after which that tree is killed.
`Catalyst.Extensions` remains the stable public facade, registered process name, and supervisor
child id. Its GenServer implementation lives in `Extensions.Server`; serialized compile/setup,
lifecycle, rollback, and prior-version restoration live in `Extensions.Load`; and user-facing
status/error rendering lives in the pure `Extensions.Presenter`. Typed ownership transitions
(claim tracking, contribution commit, module-conflict checks, owner drop/snapshot, purge-result
recording) live in `Extensions.State`; caller-independent locking and generation capture live in
`Transaction`; accepted BEAM stacks and every restoration operation live in `ModuleVersions`;
and all source discovery, owner derivation, and managed-path checks live in `Sources`. A loader
contribution is a typed `%Extensions.Contribution{}`, and owner-id conventions (`:host` for host
registrations) are shared via `Extensions.Owner`. A failed purge does not forget the owner: its
entry stays tracked as `:degraded` with per-subsystem `purge_failures`, so live residue is never
orphaned.

At init, `Application.spec(:catalyst_web, :vsn)` distinguishes a web-capable runtime from the
core-only CLI/headless runtime. Headless startup begins bootstrap immediately. Web-capable startup
publishes `{:waiting_for_host, :web}` until both the application and registry leases name live
processes and the host calls the idempotent `Extensions.bootstrap/0`. Bootstrap state is tracked
separately as `:waiting`, `:running`, or `:complete`; a successful explicit `load_all/0` can win
while waiting and completes the remaining publication workflow without running extension setup
again. A replacement server also starts automatically when the persisted leases are still live.
One supervised workflow publishes the guide, runs the registered reseeders under a deadline, then
performs the boot load. Guide/reseeder failures are logged and nonfatal. Hook readiness (which
gates per-turn snapshots) is published after the workflow for successful, failed, and safe-mode
outcomes, leaving built-in recovery tools usable. A failed boot load retains its armed BootGuard
marker. Thus arbitrary `setup/1` side effects execute exactly once rather than once in core and
again in web.

The UI ETS
table has an independent `UI.TableOwner`, which buys **read continuity**: renders keep resolving
pages/renderers while the registry process is down or restarting. Durability of accepted
contributions comes from `UI.Contributions`, which serializes the exact live page, renderer,
component, and command entries and
mirrors them in `:persistent_term`; after table-owner or contribution-log process loss, the
registry replays those values directly. `UI.Registry.init/1` deliberately **wipes** the ETS table
before reseeding built-ins and replaying that log: `purge_extension_owner/1` drops the owner's
contribution-log entries first and skips the ETS delete when the registry process is down, so a
surviving table row could otherwise resurrect a purged owner — the log, not the table, is the
authority. Recovery never reads edited source, recompiles modules,
or re-runs arbitrary `setup/1` side effects. Each load transaction and `ExtensionAPI` handle is
pinned to the `Catalyst.Extensions` server generation that created it, so returned work that
outlives a restart is rejected instead of committing into the replacement runtime. Before a
safe-mode generation publishes readiness, it revokes the prior generation's recorded owners and
restores or removes their accepted modules. Extension API dispatch takes a generation gate around
its current-generation check and handler call; a load that discovers its captured generation is
stale restores every compiler-traced candidate before releasing the load lock. Compiler workers
reserve a provisional entry before their start gate and journal emitted modules in
`:persistent_term`, but replacement does **not** currently invoke
`CompilerTracer.drain_provisional/0`. Reproducing an orphan compiler and benchmarking the
persistent-term write/global-GC cost are explicit follow-ups before that store or recovery path is
changed. Boot generation checks prevent an older asynchronous result from overwriting a newer
explicit outcome.

**Crash-safe boot (`Catalyst.Extensions.BootGuard`).** `CATALYST_SAFE_MODE=1` skips loading
manually; the boot marker makes it **automatic**: a marker file is set to `booting` before
`load_all` and flipped to `ok` after a stabilization window (default 10s). A boot that finds a
stale `booting` marker knows the previous boot died with extensions active, skips loading, and
reports `{:safe_mode, :crash_detected}` via `Extensions.boot_status/0` (surfaced as a banner in
`ShellLive`) — so a bricking extension is recovered by a plain relaunch, no terminal needed. The
state is sticky until an explicit, successful `reload_extensions` marks the boot `ok`. A boot
load/preflight failure is recorded as `{:load_failed, reason}`, logged, shown in the extensions
panel, and deliberately leaves the marker armed; it is never silently marked clean.

**Prompts and workflows are data.** `Catalyst.Prompt.Registry` selects a runtime prompt policy,
then the live `:prompt_policy`, then `Catalyst.SystemPrompt`. The built-in policy resolves system
text by session override → runtime exact model id/API/default → live `:prompts` → model/API files
under `~/.catalyst/prompts/` → `system_prompt.md` → built-in, then adds nonblank `append.md`.
Compaction has its own runtime/application/model-file/`compaction.md`/built-in chain and never uses
the session system override or append file. Each result includes final UTF-8 text, SHA-256 digest,
and ordered provenance. Files have no watcher: prewarm and the run resolve independently; the run
caches system resolutions by model key; compaction resolves when attempted. Dynamic prompt text
is permitted but invalidates request probes and provider delta reuse.

`Catalyst.Workflow.Registry` selects a session `opts[:loop]` module, named
`opts[:workflow]`, runtime/application default, live `:agent_loop`, then `Catalyst.Agent.Loop`.
Unknown explicit names fail rather than falling through. Selection data is pinned per run, but
ordinary BEAM semantics still apply if the selected module is hot-reloaded. A conforming workflow
uses `Workflow.Support`; guarded successful provider responses come back with a provider-accurate
context digest when the provider implements the fingerprint adapter, and the workflow emits the
shared post-persistence anchor status after its `MessageEnd`. A sovereign workflow that calls the
provider directly bypasses context guarding and observer/capability helpers and is unsupported. It
must emit one initial `AgentStart`,
`MessageEnd` for every persistable user/assistant/tool-result message, normally balanced tool
boundaries/results, and one final `AgentEnd`. Normal return does not synthesize missing lifecycle
events; brutal task cancellation can interrupt a boundary pair.

**Executable proof boundary.** The serial `:flexibility` tier composes these seams in the normal
test VM, exercises real sessions/renders, explicitly reverts controlled effects, and compares the
result with a suite-wide registry/module/process/path/config baseline. It also fingerprints every
Elixir block in the bundled guide and executes or statically validates each classified example.
The opt-in `:release` tier builds a plain headless `catalyst_cli` OTP release into a temporary path,
then proves runtime compilation, a scripted persisted session, `CATALYST_HOME` isolation, and
crash-marker safe mode in fresh release VMs. This does not claim that arbitrary file/network/
external side effects are reversible, and the headless artifact contains no Phoenix/HEEx/assets;
packaged GUI and runtime asset rebuilding remain the manual `.app` verification described in §8.
The CLI self-test creates one exclusive, uniquely named source under the OS temporary directory and
loads it directly under the extension transaction lock; it never rewrites `CATALYST_HOME`, the live
extension directory, or the boot-marker path, and removes only its own contribution/source.

**Hook points (`Catalyst.Hooks`, ETS bag).** Six PI-style points, wired into `agent/loop.ex` +
`tool_runner.ex`, **no-op when empty**. Decision/filter handlers run in isolated supervised tasks
with a deadline. Read-only observers are delivered by `ObserverDispatcher`: one directly
supervised callback process at a time per session, ordered within a session and concurrent across
sessions. A crashing or hanging callback is logged, killed, and skipped. Per-session admission is
bounded; streamed `MessageUpdate`/`ToolExecutionUpdate` events may be dropped at saturation, while
ordinary structural events evict an older queued update or apply backpressure. Successfully
persisted compactions freeze the first complete handler snapshot read from the durable handler
table (committed admission deliberately does not wait on hook-runtime readiness, so a
still-bootstrapping extension generation cannot strand a session) and are admitted to an ordered
waiting lane before broadcast, without running
observer callbacks in the Session GenServer. Direct dispatcher/registry downtime retries only
admission against that frozen snapshot, bounded by a configurable deadline
(`:event_sink_deadline_ms`, default 500 ms); at the deadline the observer handoff is dropped with
a logged warning while persistence and PubSub delivery are unaffected. Queue overload never drops an admitted compaction, but a dispatcher
crash after acknowledgement can lose queued callback work and an ambiguous failed admission can
be retried, so observers must tolerate both process loss and duplicate delivery. Host-synthesized
failure/abort lifecycle
events use bounded non-blocking admission: they evict a queued update when possible and otherwise
may be dropped from observer delivery under saturation (PubSub delivery is unaffected). Admission
and enqueue are one GenServer operation, eliminating leaked pre-cast reservations. The dispatcher
is supervised outside the extension-runtime group so admitted queues survive registry recovery.
The ETS handler table lives in a separate `TableOwner` process inside a `:rest_for_one` group, and
generation tokens prevent a stale runtime from publishing readiness, so recovery cannot silently
observe a fresh but incomplete handler table:

| Point                    | Where                                                | Power                                                                                                        |
| ------------------------ | ---------------------------------------------------- | ------------------------------------------------------------------------------------------------------------ |
| `transform_context`      | before converting `context.messages`                 | request-only rewrite/redact; it does **not** persist compaction                                              |
| `before_tool_call`       | between tool fetch and execute                       | `{:block, reason}` → error result, tool not run                                                              |
| `after_tool_call`        | after execute, before `ToolExecutionEnd`             | rewrite the result tuple                                                                                     |
| `prepare_next_turn`      | after `TurnEnd` (every turn, incl. the natural stop) | return `%{context, config}` for the next turn                                                                |
| `should_stop_after_turn` | after every turn                                     | force-stop the loop AND skip the follow-up queue                                                             |
| `on` / `notify`          | `emit` wrapper + durable/synthetic event sinks        | ordered observers; lossy updates, lossless committed compactions, bounded synthetic lifecycle admission       |

**Registries that resolve live.** `Catalyst.LLM.Registry` (§6) resolves providers;
`Catalyst.Prompt.Registry`, `Catalyst.Workflow.Registry`, and `Catalyst.Context.Registry` hold
owner-aware runtime overlays for prompt policy/text, named/default workflows, and context
policy/thresholds. Owner bookkeeping is a column in each registry's own ETS rows (the pure
`Catalyst.OwnedIndex` helper now backs only `LLM.Registry`, where multi-key ownership pays for
it), owner-id normalization is shared via `Extensions.Owner`, and ownership conflicts are reported
in one normalized shape — `{:owner_collision, kind, key, existing, attempted}` (`key` is `nil`
for single-slot kinds such as the context policy); each registry retains its own validation, ETS
shape, fallback layers, and domain error tuples. Each lookup reads the runtime entry first, then current application
configuration, then its documented file/built-in layers; deleting an overlay never re-seeds a
stale boot value. Their `runtime_entries/0` results expose `key`, `value`, and `owner` fields for rollback and
diagnostics. `CatalystWeb.UI.Registry` resolves **pages / renderers / components / commands**.
`CatalystWeb.UI.MessageRenderer` dispatches transcript rendering to registered renderers
(newest-first, `match_fun`) falling back to built-ins. Routing is **catch-all**: one
`CatalystWeb.ShellLive` is mounted at `/` and `/:page` (router ships this once), and
`handle_params` resolves the page registry by path — so a new page (`/settings`) is a registry
write, no router recompile. The chat itself is just a registered page (`Pages.ChatPage`), and
the commands registry is dogfooded the same way: `/cd` is a seeded built-in command, and every
`/name [arg]` chat message dispatches through `UI.Registry.fetch_command/1` (crash-isolated
handlers; unknown names flash the known list).

**Apply-cost matrix.** new tool/provider/prompt/workflow/context-policy/hook/renderer/page/panel →
registry write (live at the next relevant run/request/render); system/compaction prompt → write
the corresponding file under `~/.catalyst/` (at the next documented resolution boundary);
workflow → `:workflows` or legacy `:agent_loop` app env (next run); background process →
`start_child` (immediate, purged with its owner); markup/layout change → hot-swap + reload
(`reload_ui`); CSS/Tailwind or new JS
hook → `CatalystWeb.Assets.rebuild/0` (runs the bundled tailwind+esbuild, §8) then a webview
reload broadcast over the `"ui"` PubSub topic.

**Self-modification tools** (all routed through the loader): `develop_tool` (write+load a tool),
`install_extension` (write+load any module — tool, provider, hook, or UI), `reload_extensions`
(purge+reload by owner), `rollback_extension` (git revert + reload; optional `name` scopes the
LIFO walk to one extension's file via `Versioning.rollback_file/2`); web boot registers
`rebuild_assets` and `reload_ui`. The agent is pointed at `./guide.md` (published to
`Catalyst.Paths.join("guide.md")` on boot, `~/.catalyst/guide.md` by default) which documents all
of this relative to the live bundled app.

**Extensions panel (human-facing recovery + introspection).** `/extensions` is a second seeded
built-in page (`Pages.ExtensionsPage`, registered exactly like `Pages.ChatPage`, so it also
dogfoods the page registry). It renders a data snapshot (`panel_data/0`, rebuilt by `ShellLive`
on navigation, after each action, and at `AgentEnd`) of: loaded extensions
(via `Extensions.snapshot/0`, the bounded UI summary — boot status, generation, and each
`list_loaded/0` owner entry (owner/file/tools/modules/status) augmented with a process count
computed in one supervised deadline-bounded task, degrading to `:unknown` rather than blocking
the render path), disabled extensions
(`Extensions.list_disabled/0`), boot status with a "Load extensions now" recovery button, and
every live registry. Prompt/workflow/context runtime owner rows are separate from the effective
ordered values/provenance for the current model; panel snapshots never call an extension's
optional `describe/0` unsafely. Tools, providers, hooks via `Hooks.handlers/1`, pages/commands, and
`UI.Registry.list_renderers/0`/`list_components/0` remain listed. Per-extension buttons: **reload**
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
`Session.EventSink`/background tasks (full reason on failure) and the `OpenAICodex.Provider`, so
default-on file IO does not run in `Session.Server` callbacks. Toggle with
`CATALYST_DEBUG=0`. Log/tool text is scrubbed to valid UTF-8 after byte bounds are applied, and a
deleted cached debug directory is revalidated and recreated on the next write. The `read_log` tool
lets the agent read its own canonical session log, and the system
prompt + guide point at it — so when something fails in the packaged app (a tool call, a stream
close, a TCC `:eperm`), the agent and the developer have the same trail. This log is how the
`Finch.stream/5` 3-tuple transport-close crash (§6 caveat) was found and fixed.

## 13. Computer use

An opt-in capability tier (planned in `hhhh.md`, delivered as P6) that lets the agent operate the
machine the way a person does: see the screen, click and type, drive native apps, reach the
network, and hold interactive shells open. **Off by default; full machine access by design when
on** — there is no sandbox and no approval UI (the counterweight is the `before_tool_call`
gate recipe in `guide.md`, plus off-by-default, non-inheritance, and untrusted marking).

- **Capability seam.** Tools declare `capabilities/0` (optional callback on `Catalyst.Tools.Tool`,
  default `[]`, cached in the Registry's validated `definition`). `Workflow.Support.
  filter_capabilities/2` — the same non-bypassable post-resolution gate that strips `spawn_agent`
  at the depth cap — now also rejects tools whose capabilities are not granted, so neither an
  extension nor an explicit `tools:` list can re-add them. The `:computer_use` grant is a session
  opt (`Session.Server.configure(pid, opts: [computer_use: true])`, header toggle, persisted in
  the `machine_prefs` persistent_term) and requires backend availability
  (`Catalyst.Tools.Computer.Availability`: Darwin + helper binary). `:computer_use` is on the
  `RunConfig.inheritable_opts/1` denylist: **child sessions never inherit the grant**.
- **Native helper.** `rel/macos/computer_helper.m` → `catalyst-input`, a long-lived
  newline-delimited-JSON process on a BEAM Port owned by the supervised
  `Catalyst.Tools.Computer.Helper` GenServer (lazy Port open so no TCC prompt at boot; permanent,
  reopens on EXIT). The helper executes strictly serially, so the Helper is **write-when-idle**:
  at most one op is in flight at the native helper, the rest wait in a bounded server-side FIFO
  (one physical pointer — a global input lock), with per-op timeout budgets, cancel-on-timeout
  reaping of still-queued ops (a timed-out op never fires later as ghost input), and a
  server-side wedge deadline that closes a hung helper and fails all waiters. **Abort safety:**
  held buttons are tracked per caller; a monitor posts the compensating mouse-up when the calling
  tool task dies. When the helper itself dies or wedges while any input op was in flight, the
  Helper reopens and posts the tracked explicit mouse-ups plus a `release_all` sweep (all five
  modifiers and tracked buttons) — best-effort: a key held inside an in-flight `hold_key` stays
  physically down between the death and the reopen. Input posts real modifier
  key events (not just `CGEventSetFlags`, which latches session state). Keycodes are layout-aware
  (`UCKeyTranslate` reverse scan). The same binary's `--test-target` mode opens an instrumented
  window reporting every event it receives — the round-trip instrument for `mix test.computer`.
- **Backend behaviour.** `Computer.Backend` (`screens/windows/cursor/input/capture/grants`) with
  `MacOS` (helper + `screencapture` + `sips`) and `Unsupported` implementations, selected by
  `config :catalyst, :computer_backend` (default `:os.type()` dispatch); tests inject a stub, so
  the whole tool surface runs with no desktop and no TCC.
- **Tools.** `computer` (Anthropic-shaped action enum; screenshots downscaled to ≤1366px,
  returned as `Content.Image`, details `untrusted: true`; coordinates are last-screenshot pixel
  space mapped through `Capture.to_point/4` — screenshot px ÷ downscale ÷ backing scale +
  display origin in points), `applescript` (osascript via temp file; the preferred zero-screenshot
  path), `open_app`, `list_apps`, `clipboard`, `shell_session` (cross-turn PTY via `script(1)`,
  per-shell supervised GenServers registered under the owning session, idle timeout + global cap +
  session-death reaping) — all gated. `fetch` (Req + Floki HTML→text, streaming byte cap,
  in-band untrusted notice) is **ungated**: it adds nothing `bash` + `curl` lack.
- **Token accounting.** Image content is projected as `digest`+`bytes` (never raw base64) in both
  the coarse and Codex-semantic estimators, priced at
  `max(1_024, div(bytes, 600))` tokens — without this the estimator counted base64 at 4 bytes/token
  and a single screenshot deadlocked compaction (§ hhhh.md Appendix A, VETO 1). The digest keeps
  fingerprinting/anchor identity; the wire request still carries real base64 (live-verified:
  Codex accepts images inside `function_call_output`).
- **Context discipline.** Prefer the semantic path (`open_app`/`applescript`) over the pixel loop;
  window-scoped capture over full-display (which shows Catalyst's own window). Optional
  `config :catalyst, :computer_screenshot_retain` prunes all but the last N screenshots via an
  idempotent `transform_context` hook (costs: full re-upload per turn, and compaction persists
  replacements untransformed). Debug logs never contain image bytes (mime+size+digest only);
  transcripts do — screenshots persist unencrypted in session JSONL (documented in `guide.md`).
- **Packaging.** `bundle_computer_helper/1` compiles + ad-hoc signs the helper into the release
  before the installer seals it; `release_preflight!/1` checks the source + `cc`;
  `Binaries` resolves `catalyst_input` with a "run `mix catalyst.computer.build`" hint;
  `NSAppleEventsUsageDescription` is inserted via `plutil` in `native_macos_launcher/1`. TCC
  grants key on the helper's cdhash (ad-hoc signing ⇒ re-grant after rebuild) and there are up to
  three TCC subjects (helper, `osascript`, the app) — see `guide.md`.
- **Verification tiers.** Always-on stub tests (gating, abort compensation, coordinate math,
  PTY against a real `script(1)` shell); opt-in `mix test.computer` drives the real window server
  through the production input path against the `--test-target` window (skips loudly without
  grants); opt-in `:live_wire` test pins the image-in-`function_call_output` wire contract.

See `plan.md` for the phased delivery sequence, exit criteria, and risks.
