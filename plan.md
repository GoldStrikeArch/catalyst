# Catalyst — Delivery Plan

Phased plan to reach feature parity with PI's core agent surface, then ship a native desktop
GUI. See `architecture.md` for the design. Reference implementation lives in `./tmp_pi`.

**Locked decisions:** project name **Catalyst** (`Catalyst.*` / `CatalystWeb.*`, app
`:catalyst`); **umbrella** project; **desktop spike first** (de-risk wx); fast-tool binaries
**bundled into the release and resolved locally** (`~/.catalyst/bin` → bundled `priv/bin` →
`$PATH` → Homebrew paths); per-OS/arch **auto-download** à la PI's `ensureTool` is **explicitly
deferred** — a missing binary raises with an install hint. The desktop risk is already
largely retired — `:wx` is present in the installed Erlang/OTP 29 and `rg`/`fd`/`sd`/`ast-grep`
are installed.

## Status

- **P0 — DONE ✅** (project in `./catalyst_umbrella/`). Umbrella scaffolded (`catalyst`,
  `catalyst_web`, `catalyst_desktop`), `CatalystWeb.Endpoint` converted to `Desktop.Endpoint`
  (ETS session), `ChatLive` spike, `Catalyst.Desktop` window child gated by
  `CATALYST_DESKTOP=1`. Verified end-to-end: `mix phx.server` renders in a browser AND the
  native wx window opens, loads ChatLive, and the **LiveView WebSocket connects + mounts
  inside the wxWebView**. `mix test` green (7 tests).
  - Gotchas captured in code: `Desktop.Endpoint`'s dynamic-port path assumes cowboy/ranch and
    breaks under Bandit on Phoenix 1.8 → initially worked around with a fixed port; since
    superseded — `config/runtime.exs` now defaults `PORT=0` (the OS assigns a free loopback
    port resolved after bind; set `PORT` to pin a fixed one). `Desktop.Auth` is
    **prod-only** (else it 401s browser/tests). Endpoint needs **`server: true`** because the
    shell boots via `mix run`, not `mix phx.server`.
- **P1 — DONE ✅** (headless core in `apps/catalyst`). Data model (`Content`/`Message`/
  `Usage`/`Model`); `Agent.Loop` + `ToolRunner` (sequential/parallel, terminate,
  error-results, steering/follow-up hooks); `Session.Server`/`Manager`/`Store` (GenServer
  single-writer, JSONL persistence, PubSub broadcast on `"session:<id>"`, abort-by-kill);
  `Exec` (Port `collect` + MuonTrap `bash`); `Binaries` resolver; `Truncate`; tools
  read/write/edit/ls/bash + grep(ripgrep)/find(fd)/replace(sd)/ast_grep(search+rewrite);
  `LLM.Faux`. Verified: a scripted read→ast_grep-rewrite→grep→done run produces the right
  6–8 msg transcript, ~48 PubSub events, a well-formed JSONL log that reloads, and the file
  is actually rewritten. **`mix test`: 23 (catalyst) + 7 (web) green.** Notes: tool-arg JSON
  schema validation (ex_json_schema) and binary auto-download deferred (resolves from PATH
  with an install hint); bash output streaming (partial `report`) deferred — both flagged in
  code.
- **P2 — DONE ✅ (offline-verified; live login pending user)**. OAuth: `Auth.{PKCE, JWT,
OpenAIOAuth, CallbackServer (Bandit :1455), TokenStore}` + `Catalyst.Auth.login_openai_codex/0`
  - `mix catalyst.login`; creds in `~/.catalyst/auth.json` (0600), single-flight refresh.
    Provider: `LLM.SSE` (Finch stream decoder) + `LLM.OpenAICodex.{Headers, Request,
StreamParser, Provider}` against `chatgpt.com/backend-api/codex/responses`; reasoning
    round-trip (`include: reasoning.encrypted_content` + replay), tool-call id `call|item`
    split, usage/stop-reason mapping; registered as api `openai-codex-responses`; never raises
    (errors → error assistant). **`mix test`: 38 (catalyst) + 7 (web) green** — incl. SSE
    decode, full stream-parser event mapping, request round-trip, and the callback server on
    :1455 (state match/mismatch). The live ChatGPT-authenticated streamed turn needs the user
    to `mix catalyst.login` (interactive browser OAuth) — everything up to the network call is
    tested. Caveat: this PI fork referenced future-dated model ids (gpt-5.4/5.5); set
    `config :catalyst, :codex_model` (or pass an id to `OpenAICodex.model/1`) to one your
    subscription serves.
- **P3 — DONE ✅**. `ChatLive` rewritten into a real chat: owns a `Session.Server` (started
  on connect), subscribes to `"session:<id>"`, and renders the live transcript — streaming
  assistant tokens, thinking blocks (collapsible), tool-call chips, and tool-result cards —
  with a prompt box, Stop (abort), New session, and a Demo/Codex provider switch. Added
  `Catalyst.LLM.Demo` (offline, input-aware: runs a real `ls`/`grep`/`find` then replies,
  word-streamed; since relocated to `apps/catalyst/test/support/` as a test-only provider)
  so the GUI is interactive without login, and a `ScrollBottom` JS hook.
  Verified: browser renders the shell; a LiveView test drives a full Demo turn (tool result +
  streamed reply); and the **native desktop window mounts ChatLive over a live socket**.
  `mix test`: 38 (catalyst) + 6 (web) green. Open with `mix phx.server` (browser) or
  `CATALYST_DESKTOP=1 iex -S mix` (window); click **Codex** after `mix catalyst.login` for
  live answers.
- **P4a — DONE ✅ (runtime extensions / self-developing agent).** `Catalyst.Extensions`
  (ETS-backed live tool registry, seeded with built-ins, compiles+loads extension `.ex`
  files at runtime via `Code.compile_file/1`); `develop_tool` built-in lets the agent write
  a new tool module and use it next turn; the loop resolves the tool set **per turn**.
  **Proven in a packaged OTP release**: `catalyst_cli` (a headless app, no wx) built with
  `mix release`, then `bin/catalyst_cli eval` compiled+loaded a new tool and called it →
  "PACKAGED HOT-LOAD WORKS". This is the BEAM answer to PI's self-developing tools: the
  shipped binary stays immutable; extensions live in `~/.catalyst/extensions/` and load into
  the running VM (the Elixir compiler ships in the release). `mix test`: 41 (catalyst) + 6
  (web) green.
- **P4b — Burrito findings (packaging).** The OTP **release assembles cleanly** (standard
  `mix release` works → this is the reliable packaging base). Burrito itself: 1.5.0 pins
  **Zig 0.15.2 exactly** (0.16 is rejected); with 0.15.2 the macOS wrapper build failed at
  link time (`undefined symbol _sysctlbyname` / `_waitpid` — a Zig/macOS-SDK toolchain
  issue, not our code). So Burrito is viable for the **headless** binary once its
  Zig/macOS toolchain is sorted, but for the **wx GUI .app** the right tool is
  elixir-desktop's `desktop_deployment` (it bundles the wxWidgets dylibs + makes the signed
  `.app`, which Burrito does not). Config left in place: root `mix.exs` `releases:` +
  `apps/catalyst_cli`. Also made `runtime.exs` generate a `secret_key_base` fallback (local
  app) instead of raising.
- **P4c — DONE ✅ (macOS `.app` via desktop_deployment).** `{:desktop_deployment, github:
...}` + root `mix.exs` `package/0` (name "Catalyst", id `dev.catalyst.app`, icon
  `apps/catalyst_desktop/priv/icon.png`, `app_name: :catalyst_desktop` — required for an
  umbrella) + a `catalyst_desktop` release with `steps: [:assemble,
&Desktop.Deployment.generate_installer/1]`. Prod config fixed for a local app: `prod.exs`
  (localhost url, no force_ssl, `start_window: true`), `runtime.exs` (loopback + port + url
  port + generated secret; the fixed port used here has since become a `PORT=0` dynamic
  default). Build = `MIX_ENV=prod mix do --app catalyst_web
assets.deploy` then `MIX_ENV=prod mix release catalyst_desktop --overwrite` (≡ `mix
desktop.installer`). Produces **`Catalyst.app`**, **`Catalyst-0.1.0.dmg`** (20M),
  **`Catalyst-0.1.0.pkg`** in `_build/prod/`, with **20 wxWidgets dylibs bundled +
  relocated to `@loader_path`** (runs without Homebrew wx). Verified launching: boots from
  the **bundled ERTS** (`Catalyst.smp`), endpoint up on 127.0.0.1:4000, `Desktop.Auth`
  gating (401 to curl), wx window opens the chat. Caveats: **ad-hoc signed** (not Developer
  ID/notarized → Gatekeeper warns; `xattr -dr com.apple.quarantine Catalyst.app` or
  right-click→Open locally; `mix desktop.notarize …` for distribution). The icon is a
  generated pixel-art alchemy flask (`rel/icon/gen_icon.py` → `apps/catalyst_desktop/priv/icon.png`,
  `rel/macosx/icons.icns` (the deployer reuses this cache when present — regenerate it with the
  icon), and the web favicon); `CatalystDesktop.DockIcon` also sets the Dock tile in dev runs.
- **GUI Codex login — DONE ✅.** In-GUI "Sign in to ChatGPT" button runs the OAuth flow in a
  supervised Task (non-blocking; pending spinner; auto-switches to Codex on success), plus a
  sign-out (⏏) button. Backend got `TokenStore.delete/1` + `Catalyst.Auth.logout/0`. Login fn
  is config-injectable (`:catalyst_web, :login_fun`) for tests. `mix test` 41+7 green.
- **Self-extension guide — DONE ✅.** `./guide.md` (canonical, for the agent + humans):
  reoriented around the **live bundled app** — where things live (`~/.catalyst/*` outside the
  bundle vs `Application.app_dir`/`:code.priv_dir` resolutions inside), the "compiled code is
  already loaded → change behavior by loading new code" rule, a how-to-change decision guide,
  and a worked `install_extension` recipe. Bundled at `apps/catalyst/priv/guide.md` and
  **published to `~/.catalyst/guide.md` on boot** (a private `Extensions` boot step). System prompt
  tells the agent it can self-extend and points to the guide + `read_log`. (Keep `./guide.md`,
  `apps/catalyst/priv/guide.md`, and the in-bundle copy in sync.)
- **P4d — DONE ✅ (runtime extensibility: "modify everything at runtime", E1–E6).** Design =
  _everything is a registry + hooks + hot-swap_. (E1) `Catalyst.Hooks` (ETS-GenServer) with 6
  PI-style loop hook points wired into `agent/loop.ex` + `tool_runner.ex` (`transform_context`,
  `before_tool_call` (block), `after_tool_call` (override), `prepare_next_turn`,
  `should_stop_after_turn`, `on`/`notify` observers) — no-op when empty, each handler
  try/rescue-isolated. (E2) `Catalyst.Extension` behaviour (`setup/1`) + `Catalyst.ExtensionAPI`
  facade (kinds wired via `:persistent_term` so core never depends on web); `Catalyst.Extensions`
  generalized to a **multi-kind loader** (registers tool modules AND runs `setup/1`), owner-tagged
  purge-on-reload, compile-before-commit (dry-run), `CATALYST_SAFE_MODE=1` skips load; git
  versioning via `Extensions.Versioning`. (E3) `Catalyst.LLM.Registry` → ETS-GenServer
  (`register_provider`/`unregister_provider`/`fetch`/`list`) + `Catalyst.LLM.ProviderConfig`;
  session resolves provider by module | api-name. (E4) thin `Session.Server`: logic extracted to
  hot-swappable `Session.{Reducer, RunConfig, Snapshot}`. (E5) `CatalystWeb.UI.Registry`
  (pages/renderers/components/commands) + `UI.MessageRenderer` dispatch + `ShellLive` (catch-all
  routes `/` and `/:page`) + `Pages.ChatPage`; `CatalystWeb.Assets.rebuild/0` (runtime
  tailwind+esbuild) broadcasts a reload over PubSub. (E6) self-mod tools `install_extension` /
  `reload_extensions` / `rollback_extension` (core) + `rebuild_assets` / `reload_ui` (web,
  `CatalystWeb.Tools.ReloadUi`, registered at boot). Locked user decisions: approval = **auto-allow** (safety = git rollback +
  safe-mode + dry-run); UI routing = catch-all; styling = ship esbuild+tailwind.
- **Debug log — DONE ✅.** `Catalyst.Debug` writes a per-session log at `~/.catalyst/debug/<id>.log`
  (+ `latest.log`) capturing every agent-loop event, each tool call+result, and the truncated
  Codex request(+bytes)/response/error — written from `Session.Server` and the provider. `read_log`
  lets the agent read its own session log; toggle `CATALYST_DEBUG=0`. Fixed a real crash found via
  the log: `Finch.stream/5` returns a **3-tuple** `{:error, exception, partial}` on transport close
  → the Codex provider now finalizes the partial / handles it (was a `case_clause`).
- **Packaging hardening — DONE ✅.** The release now bundles a **self-contained esbuild/tailwind
  asset workspace** into the `.app` (`<webapp>/priv/asset_build/{assets,lib,bin}` + the JS `deps/`
  esbuild resolves) so `Assets.rebuild/0` works packaged — VERIFIED by deleting the served assets
  and rebuilding inside the `.app`; `config/{runtime,prod}.exs` switched to **no-digest** serving so
  runtime rebuilds overwrite the served files. It also bundles the **fast-tool binaries**
  (rg/fd/sd/ast-grep) into `lib/catalyst-*/priv/bin` (a GUI `.app` has a minimal PATH). Packaged-app
  file-access fixes: session cwd defaults to `$HOME` when `RELEASE_NAME` is set (was the erts dir),
  repointable with a **`/cd <path>`** chat command; **macOS TCC** limitation documented
  (`~/Desktop|Documents|Downloads` → `:eperm` "not owner"; grant Full Disk Access or keep projects
  elsewhere).
- **Native arm64 launcher — DONE ✅.** Every shipped binary was already arm64, but the `.app`'s
  `CFBundleExecutable` was the `run` **bash script** → a script has no Mach-O header, so macOS
  mislabeled the bundle "Intel" and launched the x86_64 slice of `/bin/bash` (Rosetta prompt). A
  permanent `native_macos_launcher/1` release step (in `mix.exs` `steps:` after `generate_installer`)
  compiles a tiny arm64 launcher (`rel/macos/launcher.c`) as the main executable (it `execv`s `run`),
  ad-hoc signs it **before** flipping `CFBundleExecutable`, then rebuilds the `.dmg`/`.pkg` from the
  fixed app. VERIFIED: arm64 main exec, `CFBundleExecutable=Catalyst`, 0 non-arm64 Mach-O in the
  bundle, dmg carries the fix. `mix test`: **78 (catalyst) + 3 (cli) + 18 (web) = 99 green.**
- **P4e — DONE ✅ (self-building hardening: safe, supervised, reversible, data-driven).**
  (1) **Auto safe-mode** — `Catalyst.Extensions.BootGuard` boot-marker file: `booting` before
  `load_all`, `ok` after a stabilization window (10s; test-config 50ms); a stale `booting` marker
  at boot = previous boot died with extensions active → skip loading, report
  `{:safe_mode, :crash_detected}` via `Extensions.boot_status/0`, amber banner in `ShellLive`;
  sticky until a successful explicit `reload_extensions` marks `ok`. A bricking extension is now
  recovered by relaunching the app. (2) **Extension processes** —
  `ExtensionAPI.start_child(api, child_spec)` → per-owner `DynamicSupervisor` (registered by
  ext id under `Extensions.ProcessSupervisor`/`ProcessRegistry`); purge/reload terminates the
  owner's whole subtree, including supervisor-restarted children. (3) **Loop + system prompt as
  data** — `Workflow.Registry.resolve/1`, consumed by `RunContext.build/4`, resolves session
  workflow/loop overrides through runtime and application fallbacks; `Catalyst.SystemPrompt.get/0`
  resolves the session override → `~/.catalyst/system_prompt.md`
  → built-in default. Both are resolved fresh per run; `ShellLive`'s hardcoded `@system_prompt`
  removed (prompt now lives in core and advertises its own override file). (4) **Reversible module
  overrides** — the loader tracks every module an extension file compiles; purge removes them from
  the VM and restores a shadowed module from its original beam on the code path
  (`:code.purge/delete/load_file`); fixed alongside: gone-file purge in `load_all` now also sweeps
  owners whose only footprint was module definitions. (5) **Validation + diffs** — `ToolRunner`
  validates tool args against the tool's JSON Schema (`ex_json_schema`, new core dep; malformed
  calls → clean error result, unresolvable schemas skip validation); new `Catalyst.Tools.Diff`
  (Myers, 3-line context, capped 200 lines) gives `edit` and `replace` a unified diff in content +
  `details`. Also: `ExtensionAPI.register_purger/1` now dedupes. Docs updated (architecture §2/§3/
  §11 + drift fixes: `Exec.bash/2` naming, deferred items marked deferred, store entry types,
  SSE timeout, `Desktop.Window app:`); guide.md (+priv copy) documents `start_child`,
  `system_prompt.md`, `:agent_loop`, auto safe-mode, module restore. \*\*`mix test`: 129 (catalyst)
  - 3 (cli) + 19 (web) = 151 green.\*\* (Note: ~25 of those tests landed in
    `tools_test`/`self_mod_test`/`truncate_test` outside this change, earlier the same day.)
- **P4f — DONE ✅ (extensions panel: human-facing introspection + recovery).** `/extensions` is a
  second **seeded built-in page** (`CatalystWeb.Pages.ExtensionsPage`, registered like `ChatPage` —
  dogfoods the page registry; trusted alongside ChatPage in `render_active_page`). Lists loaded
  extensions (new `Extensions.list_loaded/0` snapshot: owner/source file/tools/modules + live
  process count), disabled extensions (`list_disabled/0`), boot status + safe-mode card with a
  "Load extensions now" button, and every live registry (tools w/ built-in vs owner badges,
  providers, hooks, pages, commands, + new `UI.Registry.list_renderers/0`/`list_components/0`).
  Per-extension actions: **reload** (`Extensions.reload/1`), **roll back**
  (`Versioning.rollback_file/2` — file-scoped LIFO revert walk incl. the `.disabled` name, then
  `load_all`), **disable/enable** (`Extensions.disable/1` renames source → `.ex.disabled` under
  the load lock + purges owner, so boot/`load_all` skip it; `enable/1` reverses; both renames
  git-committed). `rollback_extension` tool gained an optional `name` arg (same scoped walk) for
  agent parity. Panel actions run one-at-a-time in supervised tasks (`ext_*` events in
  `ShellLive`, flash + snapshot refresh in `handle_info`; refresh also on navigation and
  `AgentEnd`); the safe-mode banner links to the panel — a bricked extension is recoverable
  end-to-end without a terminal. Also fixed alongside: patching away from chat and back replays
  the transcript from the session snapshot (`replay_transcript/2`, shared with reattach) — stream
  items lived only in the DOM the other page replaced, so the conversation used to come back
  blank. Verified in the dev server (panel renders all sections; nav shows Chat/Extensions).
  **`mix test`: 218 (catalyst) + 3 (cli) + 37 (web) + 2 (desktop) = 260 green.**
- **P5a — DONE ✅ (Codex run settings + websocket transport).** Researched against the real
  Codex CLI (`openai/codex`), which is authoritative over this PI fork. The bundled fallback
  now lists gpt-5.6-sol / gpt-5.6-terra / gpt-5.6-luna ahead of gpt-5.5 / gpt-5.4 /
  gpt-5.4-mini / gpt-5.3-codex / gpt-5.2 (so the "future-dated ids" caveat from P2 is
  obsolete). Sol/Terra expose low/medium/high/xhigh/max/ultra reasoning, Luna through max,
  and older entries through xhigh; "Fast" = `service_tier: "priority"` (~1.5x speed,
  increased usage; the GPT-5.6 family plus gpt-5.5/5.4); every model says
  `prefer_websockets: true`. (1) **Model catalog** — `OpenAICodex.list_models/0` (+
  `catalog_entry/1`, `efforts/0`) mirroring the CLI's bundled list, overridable via
  `config :catalyst, :codex_models`; custom `:codex_model` ids always included. (2) **Run
  options** — `Request.build` gained `service_tier`; new `Session.Server.configure/2` merges
  model/provider/opts into session state for the NEXT run (nil deletes a key), `Snapshot`
  exposes `opts`. (3) **WebSocket transport** — `LLM.OpenAICodex.WebSocket` (new deps:
  `mint_web_socket`; test-only `websock_adapter`): upgrade on the same `/codex/responses` path
  with `OpenAI-Beta: responses_websockets=2026-02-06` (the CLI sends it on the handshake; PI
  drops it — followed the CLI), one `response.create` text frame per turn, JSON event frames
  (`response.done` → `completed`), ping→pong, idle/connect timeouts, fragmented frames
  reassembled by mint_web_socket. Provider transport selection `:auto | :websocket | :sse`
  (opt or `config :catalyst, :codex_transport`, default `:auto`): ws connection cached in the
  run task's process dictionary (reused across turns, dies with the run — no leak path),
  stale-reuse reconnects once, upgrade-401 drives the same single token-refresh retry as SSE,
  `:auto` falls back to SSE only when ws failed before any event reached the sink (after that
  the partial turn is finalized, like an SSE transport close). (4) **Header UI** (Codex only):
  model / effort / transport selects + ⚡ Fast toggle (only on tier-capable models, clamped off
  otherwise); applied live to the running session via `configure` — no session restart, the
  transcript stays; persisted in persistent_term and restored from the session snapshot on
  reattach. Tests: ws client round-trip against a local Bandit websocket server (ping→pong
  gating, done-normalization, connection reuse, close-before-terminal, rejected upgrade),
  provider auto→SSE fallback, request service_tier, Server.configure merge/delete, catalog
  config overrides, and LiveView control wiring (2 tests). The 401-retry provider test pinned
  to `transport: :sse` (its subject). **`mix test`: 229 (catalyst) + 3 (cli) + 39 (web) + 2
  (desktop) = 273 green.** Next within this area: live model list from `GET /codex/models`,
  websocket connection reuse ACROSS runs + `previous_response_id` cached-context deltas (the
  CLI's big upload win), usage-limit/retry-after surfacing in the UI.
- **P5b — DONE ✅ (UI: Codex-only + "@" file references).** (1) **Demo provider removed from
  the UI** — Codex is the only provider: no Demo/Codex switch, sessions always start with the
  Codex provider + the saved run settings; sign-in/sign-out no longer restart the session (the
  loop pulls a fresh token per turn, so login mid-conversation keeps the transcript); the
  not-authenticated error now points at the header button. `Catalyst.LLM.Demo` survives with no
  UI surface as the test-only provider (now in `apps/catalyst/test/support/`), registered for
  the Codex API through `Catalyst.LLM.Registry` by the web test helper. (2) **Header decluttered** — removed
  the "Catalyst" brand text and the model-label chip (the model select already shows it); the
  provider pill buttons are gone; `<title>` keeps the app name. (3) **"@" file search** —
  `CatalystWeb.FileSearch` (fd via `Binaries`/`Exec`, `--full-path`, ≤8 results, 3s deadline,
  degrades to `[]`): a trailing `@query` in the chat input (150ms debounce) opens a dropdown;
  labels are `@<parent>/<name>` extended upward per colliding group only
  (`@session/server.ex` vs `@qwe/server.ex`; unique files stay short); picking (click, or
  Enter = first match while the dropdown is open) inserts the label and remembers
  `label → cwd-relative path`; on send the labels expand for the model (longest-first
  replacement). Refs reset with the session; `/cd` re-roots the search. Tests: FileSearch unit
  (disambiguation, full-path queries, broken-pattern degradation), LiveView flow
  (dropdown → pick → expansion through a real run, Enter-picks-first), login-without-restart;
  obsolete Demo-era tests rewritten/removed. **`mix test`: 229 + 3 + 45 + 2 = 279 green.**
- **Streaming scrollback fix — DONE ✅.** During a streaming response the user couldn't scroll
  up: every delta's autoscroll re-latched the `ScrollBottom` hook's 80px position heuristic
  (its own programmatic scrolls landed at the bottom and re-pinned it), yanking the view back
  before an upward gesture could escape. Rewrote the hook (`apps/catalyst_web/assets/js/app.js`)
  around explicit user intent: wheel-up/touch/keys unpin BEFORE the browser applies the scroll
  (winning the race against per-delta snaps); the hook's own scrolls are recognized by landing
  position (±1px `programmaticTarget`) and never recompute the pin; direction-aware scroll
  handling covers scrollbar drags + momentum tails; landing at the hard bottom always re-pins
  (also absorbs the browser's scroll-clamp when a `stream_tail` trim shrinks content);
  autoscroll coalesced to one rAF per frame. Added a floating **"Jump to latest" pill**
  (`chat_page.ex`: relative `min-h-0` wrapper around `main#messages` + `phx-update="ignore"`
  overlay; visibility toggled client-side by the hook, click = re-pin + instant scroll).
  Fixed alongside: `mix format` had split the glued `#stream-thinking`/`#stream-tail` content
  onto their own lines — whitespace inside `whitespace-pre-wrap` regions rendered as a blank
  line and defeated `empty:hidden` — both now `phx-no-format` with glued content. Also added
  a root `CLAUDE.md` (thin `@AGENTS.md` import + Claude-specific pointers). `StreamingMessage`
  hook unchanged. **`mix test`: 262 + 3 + 58 + 2 = 325 green**; served markup/bundle/icon CSS
  smoke-tested against a dev server. Scroll behavior itself is client-side physics (not
  LiveViewTest-able) — verify by streaming a long reply and scrolling up mid-stream.
- **Quiet mode — DONE ✅.** Header **Quiet** toggle (next to the Codex cluster; provider-
  agnostic) that hides transcript process noise: tool-call chips, tool-result cards, and
  thinking (committed `<details>` + the streaming `#stream-thinking` region). Live "running
  tool…" spinners stay visible as the activity signal. **Display-only via CSS**: the toggle
  sets `data-quiet` on `main#messages` and unlayered `[data-quiet] …` rules in `app.css` hide
  the noise — chosen because stream/ignore regions never re-render on assign changes, so a
  server-side conditional would need a full transcript re-stream per toggle; CSS is instant,
  retroactive, reversible, and works mid-stream. New stable hooks: `data-block-kind=
"text|thinking|tool-call"` on the built-in block renderers (tool-result cards already had
  `data-message-role`); a `:has()` rule collapses assistant bubbles left empty by hiding
  (streaming bubble unaffected — different role value). Wiring mirrors the ⚡ Fast pattern but
  UI-only: `ui_prefs` in a **separate** persistent_term (`sync_codex_ui` rebuilds
  `codex_prefs` wholesale on reattach and would drop a key stored there), `toggle_quiet`
  event, `quiet_button_class/1`; never calls `Server.configure`. Tests:
  `quiet_mode_test.exs` (toggle flips `#messages[data-quiet]`, persists across remount,
  markup stays in DOM + session untouched while quiet, app.css selector guard) +
  a `data-block-kind` contract test in `message_renderer_test.exs`. **`mix test`: 262 + 3 +
  64 + 2 = 331 green**; dialyzer clean. Visual hiding is CSS (not LiveViewTest-able) —
  verify by clicking Quiet during/after a Demo run.
- **Flexibility proof suite — DONE ✅.** A serial, default-on `:flexibility` tier composes and
  explicitly reverts the supported runtime seams across real core sessions and LiveView renders,
  with a normalized baseline detector for leaked registrations, modules, processes, sessions,
  paths, config, prompts, and boot state. The bundled guide's six Elixir examples are
  fingerprint-classified and executable/static checked. The opt-in `mix test.release` tier builds
  a plain headless `catalyst_cli` release in a temporary path and checks the
  `PACKAGED HOT-LOAD WORKS`, `RELEASE TURN OK`, and `RELEASE SAFE MODE OK` sentinels in isolated
  fresh VMs. The flex tier has since grown to **36 tests (7 core + 29 web)**; the earlier cold
  release build took **25.2s**, and a warm integrated `mix test.release` run took **3.0s**. The automated
  release proof deliberately excludes Phoenix/HEEx/runtime assets; packaged GUI behavior remains
  a manual `.app` smoke.
- **P5c — DONE ✅ (purpose-aware prompts, guarded context, workflows, and child sessions).**
  Run construction moved out of `Session.Server` callbacks into supervised
  `Session.RunContext`, which pins prompt/workflow/catalog selection and reports current or
  last-successful diagnostic metadata. Three owner-aware runtime-overlay registries now cover
  prompt policy/text, named/default workflows, and context policy/thresholds, with live
  application/file/built-in fallbacks and extension purge/collision semantics. System and
  compaction prompts resolve independently by exact model id/API/default with digest and ordered
  provenance. Model catalog context metadata feeds request-time token fingerprinting, anchored or
  coarse estimates, absolute/ratio/disabled thresholds (`:none` explicitly disables Catalyst
  compaction), and staged persistent compaction; durable
  `ContextCompacted` JSONL replacements and transient `ContextStatus` drive resume and the chat
  meter. `Catalyst.Workflow`/`Workflow.Support` make the built-in loop and extensions share
  observed events, final tool capability filtering, and the context-guard provider seam.
  `list_agents`/`spawn_agent` run fresh file-backed definitions in real, exclusively-created child
  sessions with inherited configuration, root-tree depth/fan-out accounting, watchdog cleanup,
  persisted topology, and bounded explicitly untrusted results. The extensions panel and chat
  expose registry provenance, prompt diagnostics, and context status without invoking extension
  description callbacks on the UI process.
- **Core simplification and durability audit — DONE ✅.** Session-store writes and persisted-line
  decoding now return tagged failures; compaction appends before reduction/broadcast and uses a
  shared `Session.EventSink` for durable, ordinary, and synthetic observer semantics. GUI sessions
  persist model and thinking-level changes together as one authoritative `settings_snapshot`
  before installing them in memory, while retaining read compatibility with the two legacy entry
  types. GUI sessions resolve providers through `LLM.Registry`, and tool execution consumes one validated, generation-
  pinned registry entry instead of calling extension metadata twice. CLI controlled exits mark the
  boot clean, while self-test uses an exclusive temporary source and never touches user extension
  state. Shared ownership bookkeeping moved into pure `OwnedIndex`; Codex token accounting and
  request construction share one projection. The stable `Extensions` facade delegates its
  GenServer state owner, serialized lifecycle saga, pure presentation, source rules, and exact BEAM
  restoration to `Server`, `Load`, `Presenter`, `Sources`, and `ModuleVersions`; the obsolete
  `RunConfig.build/3`/`resolve_loop/1`
  entry points and the `ModuleScan` module were removed (`Session.RunConfig` itself remains the
  heavily used host-side run preflight). Extension setup now has one host-controlled
  `:waiting | :running | :complete` bootstrap, and exact live UI contributions replay after table
  loss without recompiling or running setup twice. Extension transactions and
  API handles are generation-pinned, prior runtime footprints are revoked before restart/safe-mode
  readiness, and stale asynchronous boot work cannot run after or replace newer explicit outcomes.
  Returned stale compilations restore their traced candidates. The provisional compiler journal
  remains in persistent term, but replacement does not currently drain it; an orphan-compiler
  reproduction and benchmark are required before wiring `drain_provisional/0` or replacing its
  storage. Extension-owner teardown is bounded even when a child
  start callback or shutdown never returns, while preserving the shared process registry. Core
  state/config types, behaviour callback docs, reverse chunk accumulation, and
  concurrent provider cleanup tighten the idiomatic Elixir/OTP boundaries; the former core compile
  cycle is gone. Debug logging of committed events runs asynchronously outside the session, while
  the observed-path debug append deliberately remains a synchronous `File.write!` in the run task
  before the event is accepted by the session — moving observation behind an accepted-event
  pipeline is a known design option, explicitly deferred.
- **Codex hardening (post-GPT-5.6 rollout) — DONE ✅.** Three field bugs root-caused from the
  debug log + a live `generate: false` replay repro: (1) **model picker desync** — selecting a
  bundled-fallback model (e.g. gpt-5.6-terra) and then having the background live-catalog
  refresh replace the options list left the `<select>` with no selected option, so the browser
  silently displayed another model; `catalog_snapshot/1` now appends a missing selected id as a
  bare entry. (2) **post-abort 400 shown as blank "Error : "** — websocket-streamed reasoning
  items store `output_index` in the Thinking signature; replaying it on the next full upload is
  rejected by the backend (`unknown_parameter`, verified live), and the ws error frame nests
  `code`/`message` under `"error"` which the parser read at the top level, blanking the message.
  Replay now strips `output_index`/`sequence_number` (repairs existing transcripts too), the
  parser handles both error shapes and never finalizes blank, and a server error carried by an
  otherwise-clean ws exchange is debug-logged. (3) **session resume `:badarg`** — `Store.Codec`
  decoded enums via whitelist + `String.to_existing_atom/1`, which crashes when no loaded module
  references the atom yet (lazily loaded VM), making `load_state` fail and resume come back
  empty; replaced with explicit total mappings. `mix precommit` (582+4+114+2 green) + dialyzer.
- **P6 — Computer Use — DONE ✅ (code complete; packaged-app TCC smoke still manual).** Delivered
  per the reviewed plan (`hhhh.md`), phases C0–C7. (C0) Spikes: live Codex turn **confirmed**
  images inside `function_call_output` are accepted (kept as a permanent opt-in `:live_wire` test);
  estimator repro measured a ~1 MB image at **263k phantom tokens**. (C1) Image token accounting
  fixed: digest+bytes projection in both coarse and Codex-semantic paths, per-image cost
  `max(1_024, div(bytes, 600))` (1 MB ≈ 1.7k, 5 MB ≈ 8.7k); wire bodies unchanged; **all persisted
  anchors invalidate once** (sessions re-anchor on the next response — expected, harmless). (C2)
  `capabilities/0` tool callback + registry-cached gate in `Workflow.Support.filter_capabilities/2`;
  `:computer_use` session opt (default off), **not inheritable by child sessions**; header
  "Computer" toggle (new `machine_prefs` persistent_term) + `/computer` page (grant status, helper
  liveness, screens/windows preview). Deviation from the plan's wording, fail-safe direction: the
  grant is persisted UI-side in `machine_prefs` and re-applied at session start, not written into
  the durable `settings_snapshot` — a headless resume therefore comes back ungranted. (C3) `rel/macos/computer_helper.m` (`catalyst-input`):
  CGEvent input with layout-aware keycodes, window enumeration, TCC preflight ops, `--test-target`
  instrumented window; supervised multiplexing `Computer.Helper` Port owner with held-input
  release invariant (compensating mouse-up on caller death/port restart), per-op timeout budgets,
  bounded FIFO; `computer` tool (full Anthropic action enum, ≤1366px screenshots as
  `Content.Image`, px→point transform incl. Retina + multi-display origins); tool-result images
  now render in the transcript (`data-block-kind="tool-image"`); `mix catalyst.computer.build`;
  **`mix test.computer` real-desktop tier ran 6/6 green** and caught a real CGEventSetFlags
  modifier-latch bug (fixed by posting real modifier key events); `before_tool_call` permission-
  gate recipe in `guide.md`. (C4) `applescript` (temp-file osascript, JXA, untrusted), `open_app`,
  `list_apps`, `clipboard`. (C5) ungated `fetch`: Req streaming byte cap (256 KB/1 MB), Floki
  HTML→text, redirect/timeout caps, in-band untrusted-content notice (new dep `floki`; also bumped
  `mint` 1.9.0→1.9.3 for EEF-CVE-2026-58229/59249 — the fetch path exposes Mint to hostile
  responses; `hackney` 1.25.0 advisories remain, transitive + no fixed release, not on the fetch
  path). (C6) `shell_session` cross-turn PTY (`script -q /dev/null`, echo + `\r\n` documented):
  per-shell supervised GenServers under `Tools.Shell.Supervisor`/`Registry`, ownership pinned to
  the calling session (foreign ids refused), idle timeout (15 min), global cap (4), reaping on
  session death verified at the OS level (script + child shell both killed via pgid). (C7)
  packaging (`bundle_computer_helper/1` before installer seal, preflight source+cc checks,
  `Binaries` `catalyst_input` entry with build hint, `NSAppleEventsUsageDescription` via plutil) +
  docs (`architecture.md` §13, `guide.md` computer-use section incl. screenshots-at-rest warning
  and TCC subjects). Debug logs never contain image bytes (mime+size+digest). Security posture is
  the locked decision: auto-allow, no sandbox, off by default, child sessions excluded, untrusted
  marking on screen/web/AX content. **`mix test`: 838 (catalyst) + 4 (cli) + 136 (web) + 2
  (desktop) green; `mix dialyzer` 0 errors; opt-in tiers: `mix test.computer` 6/6,
  `:live_wire` 1/1.** Remaining manual residue (needs a human at the keyboard): packaged-`.app`
  TCC grant flow + rebuild re-grant, revoked-grant `/computer` reporting, and the LibreOffice
  zero-screenshot drive (LibreOffice not installed).
- **Open project folder — DONE ✅.** The sidebar's **+** (next to "Projects") now opens a project
  instead of a sibling thread: `CatalystWeb.FolderPicker` is a config-injected seam
  (`config :catalyst_web, :folder_picker`, a 1-arity fun → `{:ok, path} | :cancelled | {:error, _}`);
  `CatalystDesktop.Application` registers `CatalystDesktop.FolderPicker.pick/1` (a wx `wxDirDialog`
  parented to the Catalyst window, `wxDD_DIR_MUST_EXIST`) when the native window is enabled, and the
  LiveView runs it in `start_async` (spinner on the button, one dialog at a time). In browser mode
  (no picker registered) the button reveals an inline path form (`~`/relative paths resolve like
  `/cd`; errors keep the form open). A chosen folder becomes the `cwd` of a **new session** started
  there (`SessionLifecycle.project_dir/2` + the existing `start_in/2`), which the persisted session
  catalog groups under its own project heading and restores on the next launch — that is the
  "remembered" project list. Header **+** and per-project **+** still start sibling threads.
  Tests: `folder_picker_test.exs` + `open_project_test.exs` (native pick / cancel / error / crash,
  form submit / relative / missing / blank / cancel). The wx dialog itself is verified by a boot
  smoke (registration + dialog construction against the live window); clicking through it is a
  manual check.
- **Sidebar order + compare project chooser — DONE ✅.** (1) Switching threads no longer
  reshuffles the sidebar: `Threads.project/2` sorted the *current* project first and threads in
  catalog (most-recently-used) order, so every click moved groups around. The catalog now persists
  a fixed `created_at` per entry (legacy rows adopt their `last_used_at`, written back on the next
  save); projects sort by name (then path) and threads newest-first by creation, independent of
  focus and recency. (2) The compare page's "Project directory" free-text field (seeded with the
  process cwd) became a **Project select** of the catalog's known projects (`basename · ~/path`,
  most recently used preselected) with an "Other folder…" option that reveals the path field;
  with no known projects the plain field remains. Tests: `catalog_test` (created_at fixed/legacy),
  new `shell_live/threads_test.exs` (order invariant under focus), `comparison_live_test`
  (free-form vs select, preselection, other-folder path feeds creation).
- **Next options:** notarize for distribution (the launcher step must then re-sign inside-out +
  re-sign the dmg); optional approval gate as an extension via the
  `before_tool_call` hook (a panel toggle could install it); optional `self_test/0` extension
  callback (loader runs it post-`setup/1`, rolls back on failure); runtime crash circuit breaker
  (auto-disable an extension implicated in repeated crashes — `disable/1` is the mechanism now);
  harden session resume across reconnect + markdown rendering; broaden providers (Anthropic,
  OpenAI Responses) now that the provider registry is runtime-registerable.

---

## P0 — Desktop spike (de-risk wx FIRST)

Stand up the umbrella and prove the GUI path end-to-end with a trivial UI.

- `mix new catalyst --umbrella`; create `apps/catalyst`, `apps/catalyst_web` (Phoenix +
  LiveView), `apps/catalyst_desktop`.
- A static `ChatLive` (no agent yet) served by `CatalystWeb.Endpoint` bound to `127.0.0.1`.
- `Catalyst.Desktop` with a `Desktop.Window` child; a `config :catalyst, :ui_mode` switch
  (`:browser` | `:desktop`).

**Exit:** `mix phx.server` renders ChatLive in a browser, and `ui_mode: :desktop` opens a
native wx window rendering the same LiveView on macOS.
**Risks:** current `:desktop` version API/config; endpoint URL wiring into the webview.

## P1 — Core loop + tools, headless

The agent engine, with no real LLM yet (driven by a `Faux` provider).

- Data model: `Catalyst.Message` / `Content` / `Model` structs (mirror `ai/src/types.ts`).
- `Agent.Loop` + `ToolRunner`: turn loop, sequential/parallel tool batches, `terminate`,
  abort-by-kill, steering/follow-up queues, per-turn hooks.
- `Session.Server` (PI `Agent` analog) + `Session.Manager` (DynamicSupervisor + Registry; the
  per-session wrapper supervisor was dropped — `Server` runs directly under the DynamicSupervisor);
  event-fold + PubSub broadcast; JSONL `Session.Store`.
- `Catalyst.Tools.Exec` (`collect` via Port, `stream` via MuonTrap) and the `Tools.Binaries`
  resolver (bundled/`~/.catalyst/bin`/PATH/Homebrew; auto-download deferred).
- Tools: `read`, `write`, `edit`, `ls`, `bash` + `grep` (ripgrep), `find` (fd), `replace`
  (sd), `ast_grep` (search + rewrite). `Truncate` (2000 lines / 50KB).
- `Catalyst.LLM.Faux` for deterministic loop tests.

**Exit:** a scripted "read → edit → bash → ast-grep" run in `iex` yields the correct
transcript, JSONL file, and event stream; `mix test` green.
**Risks:** ast-grep/sd exact CLI surface + JSON shape; MuonTrap process-group kill on macOS;
binary-download asset-name mapping per OS/arch.

## P2 — OpenAI Codex provider + OAuth

Real ChatGPT-subscription auth and streaming.

- `Auth.PKCE`, `Auth.OpenAIOAuth`, `Auth.CallbackServer` (Bandit on `127.0.0.1:1455`),
  `Auth.JWT` (account id), `Auth.TokenStore` (load/save `~/.catalyst/auth.json` 0600,
  single-flight refresh).
- `LLM.OpenAICodex`: `Request` (body), `Headers`, `LLM.SSE` (Finch stream decoder),
  `StreamParser` (Responses events → normalized events), reasoning round-trip,
  retry/usage-limit handling; loop's `get_api_key` pulls a fresh token each turn.

**Exit:** real login via the browser callback, then a live streamed Codex turn that executes
a tool, end-to-end in `iex`; `~/.catalyst/auth.json` written 0600 with account id; forced
near-expiry verifies single-flight refresh.
**Risks:** live SSE event set/ordering; `reasoning.encrypted_content` round-trip;
token-refresh concurrency.

## P3 — Wire real sessions into LiveView

Replace P0's static UI with the live agent.

- `ChatLive` subscribes to `"session:<id>"`; renders streaming tokens, thinking blocks, and
  tool-call cards driven by live `tool_execution_update`.
- Prompt input; steering + abort controls; session resume from JSONL.

**Exit:** full live chat with streaming + tool rendering, in both the browser and the desktop
window; abort mid-run works; a persisted session resumes.

## P4 — Desktop packaging

- `MIX_ENV=prod mix release` + elixir-desktop macOS `.app` packaging; bundle the fast-tool
  binaries (auto-download deferred); code-sign / notarize.

**Exit:** double-clicking the `.app` opens the native window running the chat.
**Risks:** packaging tooling/version; signing/notarization.

## P5 — Breadth (toward full PI parity)

> The runtime-extensibility foundation from **P4d** is the substrate for most of P5: providers
> register into `LLM.Registry`, a permission gate is just a `before_tool_call` hook extension,
> and new panels/pages are `UI.Registry` writes. These can now ship as extensions, not core edits.

- More providers behind `LLM.Provider` (Anthropic, OpenAI Responses non-Codex, completions) via
  `LLM.Registry.register_provider/3` + `ProviderConfig`.
- Device-code OAuth; websocket reuse across runs + cached-context deltas
  (`previous_response_id`); session branching; permission gating via the
  `before_tool_call` hook surfaced in the LiveView; additional fast tools as needed.

## P5c — Prompt, context, workflows, and supervised child sessions

This slice is delivered in dependency order rather than deferred as generic P5 breadth:

1. Move extension callbacks and run assembly behind the supervised `Session.RunContext` boundary;
   keep synchronous host-owned busy/provider checks in `Session.Server`.
2. Add purpose/model-aware prompt resolution and provenance. Persistent compaction depends on its
   compaction-purpose prompt; prompt work therefore precedes the context guard.
3. Normalize effective catalog limits, deterministic request accounting, context policy and
   threshold overlays, staged compaction, durable JSONL replacement events, and UI stream reset.
4. Add `Workflow.Registry`, `Workflow.Support`, and the `Catalyst.Workflow` contract. This registry
   is independent of compaction, while conforming workflows consume the guard seam once present.
5. Add file-backed `list_agents`/`spawn_agent`, exclusive child creation, persisted topology,
   root-tree depth/fan-out ownership, final capability filtering, watchdog cleanup, and bounded
   results. Child sessions could exist without compaction, but landing them after the guard gives
   long-running parents and children the same context safety.

No built-in orchestrator workflow is included: `Agent.Loop` already runs independent tool calls
concurrently, and alternative scheduling belongs behind the workflow registry when it has a
distinct contract.

**Exit:** prompt/workflow/context registry precedence and owner purge are tested; a resumed
session folds durable compaction; chat streams reset on `ContextCompacted` and status updates do
not create transcript blocks; custom conforming workflows use the guard; child sessions preserve
root/depth metadata, respect tree-wide capacity, reap on parent death, and return bounded
untrusted output.

---

## Verification (per phase)

- **P0:** `mix phx.server` (browser) + `ui_mode: :desktop` (wx window) both render ChatLive.
- **P1:** `iex -S mix`; `Catalyst.Session.Manager.start_session(cwd: ".")`; drive a `Faux`
  run; assert transcript + emitted events + JSONL; exercise each tool (rg/fd/sd/ast-grep
  search+rewrite, bash timeout/abort) against a temp dir; `mix test`.
- **P2:** run OAuth login (callback on :1455); confirm `auth.json` 0600 + account id; run a
  live Codex prompt and observe streamed deltas + a tool call; force near-expiry to verify
  single-flight refresh.
- **P3:** in browser and desktop window, send a prompt and watch live streaming + tool cards;
  abort mid-run; resume a persisted session.
- **P4:** run `mix test.flex` (also included by ordinary `mix test`/`mix precommit`); run the
  opt-in `mix test.release` and observe `PACKAGED HOT-LOAD WORKS`, `RELEASE TURN OK`, and
  `RELEASE SAFE MODE OK` from a temporary plain headless release; then build and launch the
  packaged `.app` for the still-manual Phoenix/HEEx/runtime-asset and end-to-end GUI smoke.
- **P5c:** focused registry/prompt/context/store/workflow/child and LiveView tests, then
  `mix precommit`, `mix dialyzer`, and `mix test.release`; manually smoke the packaged context
  meter, compaction transcript replacement, prompt provenance, and parallel child tools.
