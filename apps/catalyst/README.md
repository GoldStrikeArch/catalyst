# Catalyst (core)

The headless agent core of the Catalyst umbrella: the agent loop, sessions and persistence,
tools, hooks, LLM providers, and the runtime-extension system. Everything here runs without
Phoenix — `iex -S mix`, tests, and the `catalyst_cli` release all drive it directly.

**Dependency rule:** core never depends on `catalyst_web` (only `phoenix_pubsub` for event
broadcast). Web-only extension kinds (pages/renderers/components/commands) are dispatched
through `:persistent_term`, so the dependency arrow only ever points web → core. See
`../../architecture.md` for the full design.

## Module map

| Area | Modules | One line |
| --- | --- | --- |
| Agent loop | `Catalyst.Agent.{Loop, ToolRunner, Event, Children}` | Turn loop, tool batches (per-turn pinned tool index), steering/follow-up, child-session leases. |
| Sessions | `Catalyst.Session.{Server, Manager, Store, EventSink, Reducer, RunConfig, RunContext, Snapshot, Catalog}` | Single-writer GenServer per session, JSONL persistence, supervised run construction, persisted `{id, cwd}` catalog for post-restart resume. |
| Context safety | `Catalyst.Context.{Guard, Window, Tokens, Compaction, Transcript, Summarizer, Registry, Policy}` | Request-time estimation/fingerprinting, thresholds, staged persistent compaction. |
| Tools | `Catalyst.Tools.*` (`Tool` behaviour, `Registry`, `Exec`, `Binaries`, `Listing`, built-ins) | read/write/edit/ls/bash + rg/fd/sd/ast-grep + self-modification tools. |
| LLM | `Catalyst.LLM.{Provider, Registry, SSE, Faux, OpenAICodex.*}` | Provider behaviour + registry; Codex SSE/websocket transports, catalog, delta uploads. |
| Auth | `Catalyst.Auth.{TokenStore, OpenAIOAuth, PKCE, JWT, CallbackServer}` | ChatGPT OAuth (PKCE), single-flight token refresh, `~/.catalyst/auth.json`. |
| Hooks | `Catalyst.Hooks` + `Hooks.{TableOwner, ObserverDispatcher}` | Six PI-style loop hook points; ordered, bounded async observers. |
| Extensions | `Catalyst.Extensions` + `Extensions.{State, Transaction, ModuleVersions, Sources, Loader, Installer, Versioning, BootGuard, Processes, Contribution, Owner, CompilerTracer}` | Runtime compile/load of extension files, owner purge/rollback, git versioning, crash-safe boot. |
| Extension API | `Catalyst.Extension` (behaviour), `Catalyst.ExtensionAPI` (facade) | The `setup/1` surface extensions register through. |
| Prompts/workflows | `Catalyst.{SystemPrompt, Prompt.*, Workflow.*}` | Purpose/model-aware prompt resolution; named/default workflow overlays. |
| Shared | `Catalyst.{Paths, Tasks, Ids, OwnedIndex, Debug, Files.AtomicWrite}` | Path roots under `~/.catalyst`, supervised tasks, per-session debug log. |

## Configuration keys (`config :catalyst, ...`)

Paths and boot:

| Key | Meaning |
| --- | --- |
| `:home` | Root for all `~/.catalyst` paths (also `CATALYST_HOME` env). |
| `:auth_path`, `:sessions_root`, `:session_catalog_path`, `:system_prompt_path`, `:prompts_dir`, `:agents_dir`, `:boot_marker_path` | Consumer-specific path overrides (win over `:home`). |
| `:extensions_dir` | Extension source discovery dir (does not move credentials/transcripts). |
| `:safe_mode` | Skip extension loading at boot (also `CATALYST_SAFE_MODE=1`). |
| `:boot_stable_ms` | BootGuard stabilization window before the marker flips to `ok`. |
| `:allow_self_modification` | Kill switch for the self-modification tools. |
| `:debug_log` | Enable/disable the per-session debug log (also `CATALYST_DEBUG=0`). |

Providers and Codex:

| Key | Meaning |
| --- | --- |
| `:llm_providers` | Map seeding extra providers into `LLM.Registry` at boot (api name → provider config). |
| `:codex_model`, `:codex_models` | Custom model id / full catalog override for the Codex provider. |
| `:codex_live_models` | Enable/disable the live `GET /codex/models` catalog fetch. |
| `:codex_transport` | `:auto` \| `:websocket` \| `:sse` default transport. |
| `:codex_conn_cache_max_entries` | Idle websocket connection cache bound. |
| `:oauth_callback_port`, `:oauth_refresh_timeout`, `:oauth_refresh_fun` | OAuth callback port and token-refresh tuning/injection. |

Prompt / workflow / context overlays (live application-config fallback layers):

| Key | Meaning |
| --- | --- |
| `:prompts`, `:prompt_policy` | Purpose/model-aware prompt texts and policy module. |
| `:workflows`, `:agent_loop` | Named workflows and the (legacy) default loop module. |
| `:context_policy`, `:context_thresholds` | Context policy module and per-model compaction thresholds. |

Timeouts, limits, seams (defaults in code; several exist mainly as test seams):

| Key | Meaning |
| --- | --- |
| `:hook_handler_timeout`, `:hook_observer_queue_limit` | Sync-hook deadline; per-session observer admission cap. |
| `:event_sink_deadline_ms` | Bound on committed-event observer admission retries. |
| `:reseed_deadline_ms` | Bound on the acknowledged reseed bootstrap phase. |
| `:prompt_policy_timeout`, `:context_policy_timeout`, `:tool_metadata_timeout`, `:extension_metadata_timeout` | Deadlines for extension-supplied callbacks. |
| `:extension_setup_timeout`, `:extension_compile_timeout`, `:extension_stop_timeout`, `:extensions_snapshot_timeout` | Extension lifecycle deadlines. |
| `:extension_runtime_max_restarts` | Restart budget of the extension-runtime supervisor group. |
| `:provider_cleanup_timeout` | Bound on provider `cleanup_session/1`. |
| `:subagent_max_depth`, `:subagent_max_concurrent`, `:subagent_id_generator` | Child-session tree limits and id seam. |
| `:fd_max_output_bytes` | `find` output cap override. |
| `:tool_argument_validator` | Tool-arg JSON-schema validator seam. |

## Tests

- `mix test` (in this app or umbrella root) — unit/integration suite, includes the serial
  `:flexibility` tier (`test/flexibility/*`): composes the runtime seams in the live VM and
  diffs against a suite-wide registry/module/process/path/config baseline.
- `mix test.flex` — just the flexibility tier.
- `mix test.release` — opt-in `:release` tier: builds a temporary headless `catalyst_cli`
  release and proves packaged hot-loading, a scripted persisted session, `CATALYST_HOME`
  isolation, and crash-marker safe mode in fresh VMs.

Before finishing any change: `mix precommit` and `mix dialyzer` at the umbrella root.
