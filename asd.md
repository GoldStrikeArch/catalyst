# Configurable prompts, model roles, and user/model-authored multi-stage workflows

## Context

P5c (qq.md) delivered the *plumbing*: purpose/model-aware prompt resolution with provenance
(`Catalyst.Prompt.*`), a workflow registry + behaviour + guarded support seam
(`Catalyst.Workflow.*`), context guarding/compaction, and file-backed child sessions
(`spawn_agent`). But all of it is only reachable via files under `~/.catalyst/`, app config, or
compiled extensions — **there is no user-facing way to configure a system prompt or a workflow,
and no concept of multi-stage workflows or per-stage models.**

Goal (user's request, structured):
1. **Per-model system prompts** — editable per model, from the UI.
2. **Workflow system prompt** — a separate prompt layer contributed by the active workflow
   (and per-stage in multi-stage workflows), composed with the per-model prompt.
3. **User-defined workflows** — declarative multi-stage workflows (explore → plan → implement →
   verify → review …) where each stage can pin a different model.
4. **Model-role steering** — map task roles (code analysis / exploration / verification /
   review / implementation) to models; stages and subagents reference roles, not hard ids.
5. **Model-authored workflows** — the agent can design a workflow as data (or full Elixir via
   the existing extension path), present it as a diagram/template, and the user saves it.

Research: 4 exploration agents (prompt subsystem, workflow subsystem, web UI, extensions path)
and 3 design agents (workflow spec/interpreter; prompt layering+roles; roles/UI/authoring), all
findings reconciled below. plan.md context: this would be **P5d**, building directly on P5c.

## Key current-state facts (from exploration; file:line verified)

**Workflow subsystem**
- `Catalyst.Workflow` behaviour: `run(prompts, context, config, emit) :: {:ok, [Message.t()], map()} | {:error, term}`; optional `describe/0` is never called anywhere.
- Registry stores **bare modules only** (`valid_workflow_module?` = exports `run/4`, `workflow/registry.ex:272`); no file layer, no payload slot; chain: `opts[:loop]` → named `opts[:workflow]` (runtime → `:workflows` config; unknown name = hard error) → default → `:agent_loop` → `Agent.Loop`.
- **Mid-run model switching is already legal**: `Map.put(config, :model, m)` + `RunContext.reconcile_request/2` (`run_context.ex:91`) refreshes catalog metadata, re-resolves the cached per-model prompt, clears the token anchor, reports metadata. **Gap**: provider is resolved once at run start and `reconcile_request` does NOT re-resolve it for a different-API model.
- All of `Agent.Loop`'s turn machinery is `defp` — no per-stage seam; calling `run/4` per stage would emit nested AgentStart/AgentEnd (contract violation).
- `spawn_agent` has no model/workflow override args; children inherit via `Tools.Context`; agent `.md` files have no frontmatter. `Session.Manager.start_session/1` already accepts model/provider/workflow freely.
- Context digests/anchors are model-specific: every stage/model switch unanchors accounting (0.70 conservative threshold until re-anchor) and forces one full Codex upload (delta probe mismatch), then deltas resume. Websocket survives (ConnCache).

**Prompt subsystem**
- System chain (first-wins): session override → runtime ETS → `:prompts` config → `~/.catalyst/prompts/<slug>.md` → `system_prompt.md` → built-in; then `append.md` always. Layer precedence dominates model-key specificity.
- **Only durable tier is files** — registry is ETS-only (no restart replay for `:host`), config is in-memory, nothing writes prompt files today. `Session.Catalog` + `Files.AtomicWrite` is the JSON-store precedent.
- `Resolution.sources` whitelist is closed (`resolution.ex:37-43`); run-local prompt cache keyed `{model.id, model.api}`; `slug/1` is lossy (collision check needed for a writing UI); `spawn_agent` passes agent body as a full `system_prompt:` override (defeats per-model layer for children).
- Live preview seam exists: `RunDiagnostics.preview/1` (supervised, returns text+digest+sources); provenance display markup exists in `shell_components.ex:291-397` / `extensions_page.ex:339-366`.

**Extensions / scripting**
- Extension `.ex` files cannot carry data (compiled value discarded; no payload channel in `%Contribution{}`); a declarative spec needs a new store. `Versioning` works per-directory (a second git repo under `~/.catalyst/workflows/` is fine); `RollbackTool` is hardcoded to the extensions dir.
- `register_kind/2` + `register_purger/1` + `register_reseeder/2` make new registry kinds cheap. Model-authored **module** workflows already work end-to-end via `install_extension` → `setup/1` → `register_workflow/4` (but `install_extension`'s description never mentions workflows, and guide.md has no authoring recipe or `~/.catalyst/workflows` row).

**Web UI**
- New page = entry in `UI.Registry.builtin_pages/0` + `PageRenderer.@trusted_pages`; pages are stateless render functions over the whole ShellLive assigns map; **all events live in `shell_live.ex`** (ext_* pattern with in-flight guard) — editors must be built-in pages.
- Settings snapshot persists **only model + reasoning_effort** — a selected workflow would not survive session restart without extending `persist_settings_snapshot/2` + `Store.append_settings_snapshot` + fold.
- No textarea/checkbox input types; map-based `to_form` only; no mermaid/svg lib (highlight.js is the vendoring precedent); `UI.Markdown` is a safe AST parser; renderer seam `register_renderer(:block, …)` exists.

## Design (reconciled from the three design agents)

### D1. Roles — `Catalyst.Roles` (closed atom set, pinned per run)

- Role set (fixed, compile-time): `[:exploration, :code_analysis, :planning, :implementation, :verification, :review]` — the five the user named plus `:planning` (needed by staged specs). `from_string/1` via explicit literal clauses is the ONLY string→role conversion.
- Storage chain (mirrors prompts): session `opts[:model_roles]` override → live `config :catalyst, :model_roles` → `~/.catalyst/roles.json` (versioned JSON via `Jason` + `AtomicWrite`; new `Paths.roles/0`, `:roles_path` override) → empty (role unbound → session model).
- `roles.json`: `{"version":1, "roles": {"exploration": {"model": "...", "effort": "..."}}, "agents": {"reviewer": "review"}}`. Unknown role keys dropped + reported (never atomized); corrupt file → tagged error + UI "rewrite" offer; binding = model id + optional effort only (fast/tier deferred).
- **`Catalyst.Roles.Table`** (bindings/sources/agents/warnings) resolved ONCE per run in `RunContext.build/4`, pinned in `config.roles` next to `catalog_snapshot` (same mixed-limits rationale). Stale model id → no binding + `{:stale_model, role, id}` warning (never an error, never rewrites the file). `metadata.roles` summary lands in run diagnostics.
- `Tools.Context` gains `:roles` (populated by ToolRunner) so children share the pinned table. New `Workflow.Support` helper for stage/role → `%Model{}` binding lookup (pure map read on pinned data).
- `spawn_agent` typed overrides: `role` (real JSON enum — compile-time set) + `model` (free string). Precedence: explicit `model` arg (**hard error** if unknown, before lease reservation) → `role` arg (soft fallback) → `roles.json` `agents` map → inherited model. **No markdown role directive** (decided: roles.json is the single source of truth; agent `.md` files stay pure prompts, honoring the no-frontmatter non-goal). Result details gain `%{role, model, role_source, role_fallback}`.

### D2. Workflow spec — data, validated at boundaries

New structs under `apps/catalyst/lib/catalyst/workflow/spec/` (one module per file):
- `Workflow.Spec`: `name` (regex `[A-Za-z0-9_-]{1,64}`), `entry`, `stages`, `description`, `version: 1`, `max_stage_transitions: 32`, `digest`.
- `Spec.Stage`: `id`, `title`, `model` (`:inherit` | `%ModelBinding{kind: :id|:role}`), `opts` (allow-list: `reasoning_effort`, `service_tier`, `transport`, `max_tokens`, `context_threshold`), `prompt` (`%PromptRef{kind: :inline|:file}`), `prompt_mode` (`:append|:replace`), `tools` (`%ToolPolicy{mode: :inherit|:allow|:deny, names, strict?}`), `stop` (`%Stop{until: :natural_stop|:signal|{:tool_used,name}, max_turns, max_tool_errors}`), `signals`, `on` (`[%Transition{when, goto, max_visits}]`, first-match; conditions: `:complete`, `{:signal,name}`, `:signal_next`, `:max_turns`, `:tool_error`, `:assistant_error`).
- JSON on disk (`~/.catalyst/workflows/<name>.json`; `Paths.workflows/0`, `:workflows_dir` override). `.json` not `.md` — qq.md non-goals exclude frontmatter/markdown workflow files; `session_catalog.json` is the precedent.
- `Spec.Codec.decode/1` = the ONLY json→struct boundary (explicit atom mapping). Two validation tiers: **Tier 1 pure** (`Spec.validate/1`: name/id regexes, duplicate/unknown stages, undeclared signals, signal-stage boundedness, opts allow-list, ≤16 stages, ≤8KiB stage prompt, ≤64KiB doc — runs in registry GenServer + before saves) and **Tier 2 environment** (`validate_environment/2`: role bound, api known, tool names live — runs at tool/save boundaries and defensively at stage entry; unknown model/tool = warning unless `strict?`).
- **No module/atom/MFA fields ever** — anything needing code goes through `install_extension` (existing compile/git/rollback/safe-mode rails).

### D3. Interpreter — `Agent.Segment` extraction + `Workflow.Staged`

- **Step 0 (prerequisite refactor)**: extract `Catalyst.Agent.Segment` from `Agent.Loop`'s private turn machinery **verbatim** (outer/inner loop, run_turn, steering, tool batches, drain). `Segment.run(context, acc, config, emit, limits)` with `limits :: %{max_turns, drain_follow_ups?, stop_after_turn}` returns an `outcome` (`:stop | :halt | :max_turns | :stop_predicate`, turns, last_assistant, tool_results). `Agent.Loop.run/4` becomes ~15 lines delegating with `drain_follow_ups?: true`; existing loop tests are the regression gate. PI-parity semantics live in exactly one place.
- **`Catalyst.Workflow.Staged`** implements `Catalyst.Workflow`: one AgentStart, prompt MessageEnds, then `drive/6` — per stage: derive stage config → emit transient `WorkflowStageStart` → `Segment.run` with stage limits → build pure `%Staged.Outcome{}` from tool results → `WorkflowStageEnd` → `Staged.Transitions.next/3` (pure; no match → `:end`; `:halt` ALWAYS `:end`, never overridden by spec). Machine state (visits/transitions/history) lives in recursion args, NOT config (hooks replace config wholesale). Follow-ups drained only at `:end`, re-entering `entry` counted against `max_stage_transitions`. Spec is **pinned by value** into `config.workflow.spec` — mid-run edits/purges cannot affect a running machine.
- **Stage config derivation** changes exactly: `:model` (via ModelBinding + pinned roles/catalog; `:inherit` = unchanged), `:provider` (re-resolved via `LLM.Registry.fetch(api)` ONLY when api changed — closes the explored gap), `:opts` (sanitized merge; `:session_id` re-asserted), `:workflow_prompt` (the layer, below), `:stage_tool_policy`, `:run_metadata.stage`. Everything else (cwd, tool_source, steering/follow-up closures, catalog snapshot, depth) untouched.
- **Per-stage tools**: `Workflow.Support.apply_tool_policy/2` runs AFTER `resolve_turn_tools/1` + `filter_capabilities/2` so a stage policy only ever narrows (cannot re-add spawn_agent past the depth cap); filters by provider-visible name. `tool_source` untouched → documented: stage tool policies don't propagate to children.
- **Signals**: inert static-schema `Catalyst.Tools.WorkflowStage` tool (`signal` required, `next`, `summary` ≤4KiB), injected into stage tool lists when the stage declares signals; interpreter scans tool results (never relies on `terminate` — batch-termination requires ALL calls). Stage protocol paragraph appended to the stage prompt layer (covered by digest/provenance — no hidden injection).
- New transient events `WorkflowStageStart/End` in `Event.t` (like `ContextStatus`: not persisted, reducer catch-all ignores, old builds degrade cleanly).
- Event contract preserved: guard before every request in every stage (via Segment → `Support.prepare_request`), one AgentStart/AgentEnd total, error return → server's normalized failure path.

### D4. Workflow prompt layer (reconciled: one composition seam, two sources)

- Mechanism (from spec design): `Catalyst.Prompt.Layer` (`mode: :append|:replace`, text, source) + `Prompt.compose/2`; `RunContext.reconcile_request/2` gains `apply_workflow_layer/2` between `reconcile_model/2` and `apply_hook_prompt/3`. `active_prompt` holds the **composed** text (hook equality check keeps working; hook prompt stays the outermost winner). Base stays cached per model key; recompose when layer or model epoch changes — no cache-key change needed.
- `Resolution.valid_source?/1` gains one variant: `{:workflow, name, stage | nil}`. Provenance reads e.g. `[{:file, prompts/gpt-5.6-sol.md}, {:file, append.md}, {:workflow, "explore-plan-implement", "plan"}]` in the existing diagnostics UI.
- Layer sources: (a) **staged specs** — stage `prompt` inline text or file ref `~/.catalyst/prompts/workflows/<spec>/<basename>.md`, read at stage entry; (b) **any named workflow** (module or single-stage) — `~/.catalyst/prompts/workflows/<slug(name)>.md`, resolved at run start into a run-level layer, so plain named workflows get a workflow prompt with zero authoring machinery. Missing layer = no overlay (absence is not an error); composition order fixed: base → workflow layer → (hook override wins whole). This is ONE overlay slot at a fixed position — not the "arbitrary prompt layers with priorities" qq.md excluded; record that justification in the guide.
- Delta/digest invalidation is automatic (composed text flows through `context.system_prompt` → request probe).

### D5. Storage, registry, selection, persistence

- **`Catalyst.Workflow.Store`**: list/fetch/save/duplicate/delete over `~/.catalyst/workflows/*.json` (**no drafts dir** — decided: direct save + activate, consistent with the auto-allow self-mod philosophy; recovery = delete/rollback like extensions); ListAgents-style discovery (validated basenames, one bad file never breaks the list); AtomicWrite; own git repo via the per-dir `Versioning` (every save committed → rollback path separate from extensions); saves stamp provenance (`authored_by: "agent"|"user"`, `session_id`, `saved_at`).
- **Registry**: second ETS table `:catalyst_workflow_specs` (`{{:spec, name}, %Spec{}, owner}`) in the existing `Workflow.Registry` GenServer (Tier-1 validation before write; cross-table collision `{:owner_collision, :workflow_spec, …}`; purge clears both tables). `selection()` gains `spec: Spec.t() | nil`; module workflows carry `spec: nil` (no consumer changes).
- Extended `resolve_named/1`: runtime module → runtime spec → `:workflows` config (value may be module OR spec map) → **file layer** `Store.fetch(name)` → `{:error, {:unknown_workflow, name}}`. Files deliberately do NOT participate in `:default`. New sources `{:runtime_spec, owner, key}`, `{:file, path}`.
- `ExtensionAPI.register_workflow_spec/4` + kind + purger wiring.
- **Session persistence**: `Store.append_settings_snapshot` gains `workflow` (with tombstone semantics like `model_set?`); `persisted_settings_changed?/2`, fold, restore extended; old builds ignore the key (non-destructive). `Settings` prefs gain `workflow`; `apply_workflow/2` → `Server.configure(pid, opts: [workflow: name])`. `Store.delete/1` → `{:error, {:workflow_in_use, ids}}` + UI confirm (unknown explicit name is a hard run error).

### D6. Prompt editor + tools + UI pages

- **Core**: `Catalyst.Prompt.Store` (target→path CRUD: `{:system, :default|{:model,id}|{:api,api}|:append|{:workflow,name,stage}}`, `{:compaction, …}`; tagged errors; 64KiB cap; path-safety assertion over `slug/1`; reuses `SystemPrompt.slug/prompts_dir`, `AtomicWrite`, `Resolution.digest/1`). `Catalyst.Prompt.Preview` (catalog-wide effective resolution, supervised task).
- **Persistence = files** (unanimous): survives restart, zero new layers, honest shadowing (`shadowed_by` shown when a higher layer wins), agent/git-visible. Registry stays the extension overlay only.
- **Tools** (static schemas, core, safe-mode available): `save_workflow` (name + opaque `spec` object validated by Codec, accepts stringified JSON; sequential; optional `activate: true` registers under `:host` — which can never displace an extension-owned name — and the description states saves are immediate and how to select the workflow), `list_workflows` (merged registry+config+file view with graph/mermaid output). `Tools.Registry.@default` gains both; `install_extension` description extended to mention workflows; guide.md gains an authoring recipe + `~/.catalyst/workflows` row.
- **Diagram** (unanimous: server-rendered, no mermaid dep): shared frozen projection `Spec.graph/1 :: %{nodes: [%{id,label,binding,terminal?}], edges: [%{from,to,label}]}` → `CatalystWeb.Workflows.Layout` (pure Kahn layout) + `Workflows.Diagram` (`<svg>`, `phx-click` per node, HEEx-escaped, no raw/1, testable `#diagram-node-<id>` ids). Plus `Spec.Mermaid.to_mermaid/1` for tool output/export/copy (text only). Extensions may register a real mermaid renderer later.
- **Pages** (decided: TWO pages — nav stays at 4 pills; built-in, trusted, ext_*-pattern events in ShellLive):
  - `/prompts` — label **"Models & Prompts"** (`Pages.PromptsPage` + `PromptsPanel` + `PromptActions`): per-model rows from `@codex_catalog` (+ api + default + append + compaction), effective text/digest/provenance via `Prompt.Preview`, editor form (add `textarea` type to `form_components.ex`), `shadowed_by` badges, honest "applies next run" flash; **plus the roles section** (`#roles-section`: one row per role — model select from catalog + "(session model)" option + effort select clamped by entry.efforts + source badge + stale-model warning; agents map editor `#agent-role-<name>`).
  - `/workflows` (`Pages.WorkflowsPage` + `WorkflowsPanel`): two provenance classes (file templates — editable; module/extension workflows — read-only w/ owner badge); LiveView streams with reset-on-handle_params (page-nav DOM trap); form-based stage editor (indexed params, single `role:…|model:…|inherit` binding select, per-stage prompt textarea, transitions, add/remove/reorder), live diagram recomputed on `wf_validate`, errors from `Spec.validate/1` → `to_form(errors:)`; activate button; delete with `workflow_in_use` confirm; chat header stage rail driven by `run_metadata.stage` + `WorkflowStage*` events.
- **Chat card** for model-authored workflows: built-in `MessageRenderer` clause on `%ToolResult{tool_name: "save_workflow"}` (not a seeded renderer — reseed doesn't cover renderers); `Spec.from_details/1` normalizes atom-keyed (live) AND string-keyed (JSONL-resumed) details; renders the diagram + saved-path + activation state + a "View & edit" link patching to `/workflows?open=<name>`; editing on the page, not in the bubble (stream staleness); quiet-mode CSS exception so workflow cards stay visible.

### Known risks (documented + tested, not blockers)

- Loop refactor regression (highest): mitigate with verbatim-move commit + existing tests as gate.
- Stage/model switch costs: one full Codex upload per switch (then deltas resume; ws retained); anchors invalidated → conservative 0.70 threshold until re-anchor (stage `context_threshold` opt is the explicit escape); prefer few, long stages — document.
- Hooks replace config wholesale: machine state lives outside config; dropped layer degrades to base and re-asserts at next stage boundary. Rule: hooks own within-stage config; the spec owns stage boundaries.
- Runaway loops bounded 3 ways (per-stage max_turns, per-edge max_visits, per-run max_stage_transitions).
- Safe mode: file specs + core tools keep working; extension-registered specs disappear → explicit `{:unknown_workflow, name}` (correct existing behavior).

## Phasing (each step lands green: `mix precommit` + `mix dialyzer`)

1. **Segment extraction** (pure refactor, zero behavior change; existing tests gate).
2. **Spec + Store + Graph/Mermaid + Paths** (pure + file IO, nothing wired).
3. **Roles core** (`Roles`/`Table`/`Config`, `Paths.roles/0`, RunContext pinning, `Tools.Context.roles`, ToolRunner).
4. **Prompt layer** (`Prompt.Layer`/`compose/2`, `{:workflow,…}` source, `apply_workflow_layer/2`, workflow prompt file chain) + **Prompt.Store/Preview** (editor backend).
5. **Registry integration** (spec table, selection.spec, file layer, ExtensionAPI kind/purger, settings-snapshot `workflow` persistence).
6. **Interpreter** (`Workflow.Staged` + StageConfig + Transitions + `WorkflowStage` tool + `apply_tool_policy/2` + stage events + provider re-resolution).
7. **spawn_agent typed overrides** (role enum + model arg + precedence + result details).
8. **Tools** (`save_workflow` with `activate:` + `list_workflows`) + guide/system-prompt/`install_extension` description updates.
9. **UI**: `/prompts` ("Models & Prompts", incl. roles section) → `/workflows` list+activate+diagram → stage editor → chat workflow card → stage rail; `textarea` input type; quiet-mode CSS.
10. **Docs + close-out**: architecture.md §4/§11 (+apply-cost matrix), guide.md ×2 byte-identical, plan.md P5d entry; flex baseline extension (`:roles_path`, `:model_roles`, `:workflows_dir`, `:workflow_prompts`-equivalents, workflow/roles file snapshots); `mix test.release`; manual packaged-`.app` smoke (stage rail, diagram, editors).

Steps 1–2 are shippable independently; 3/4 are parallel; UI phases follow their core counterparts.

## Verification

- **Core**: spec codec/validate (every tagged error; no atom creation from unknown strings — doctests included); store discovery/traversal/corruption/atomicity; roles precedence + stale-model warning + mid-run pin (rewrite roles.json between two Faux requests → both use pinned binding); registry precedence/tie/purge/collision across both tables; prompt layer composition/digest/provenance/model-epoch survival/hook-wins; Segment limits + unchanged `loop_test.exs`; interpreter suite vs stub provider (one AgentStart/End, guard per request incl. first of each stage, model per stage, layered prompt order, signal/max_visits/transition-limit/halt semantics, tool-policy narrowing, no spawn_agent past depth cap); spawn_agent precedence table incl. hard-error-before-lease; settings-snapshot workflow round-trip + legacy fold; save_workflow validation + never-touches-extensions-dir; delta full-body-then-re-anchor after stage switch.
- **Web**: pure Layout tests; LiveView tests by element ID only (`#prompt-row-<slug>`, `#prompt-form`, `#roles-section`, `#role-model-<role>`, `#workflow-form`, `#stage-card-<i>`, `#diagram-node-<id>`, `#workflow-errors`, activate → `Server.state(pid).opts[:workflow]`); navigation stream-reset regression; workflow chat-card flow via a Faux run calling `save_workflow` (incl. resumed string-keyed details, `activate: true` registering under `:host`).
- **Flex tier**: baseline env keys + file-manifest dimensions; extension registers a spec → real session runs it → purge → `assert_clean!`; UI-authored prompt/role/workflow writes explicitly reverted.
- **Close-out**: `mix precommit`, `mix dialyzer`, `mix test.release`, manual packaged-GUI smoke.

## Decisions (confirmed by user 2026-07-28)

1. Model-authored workflows: **direct save + optional `activate: true`** — no drafts/approval gate; consistent with the auto-allow self-mod philosophy; recovery is delete + the workflows dir's own git versioning.
2. Navigation: **two pages** — `/prompts` ("Models & Prompts", incl. roles) and `/workflows`.
3. Agent role declaration: **roles.json only** — no markdown directive; agent `.md` files stay pure prompts.
4. Delivery: **full sequence** in dependency order (phases 1–10 above).
