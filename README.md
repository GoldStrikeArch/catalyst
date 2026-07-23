# Catalyst

An Elixir/OTP coding-agent harness with a native desktop GUI. Catalyst reimplements PI's
minimal agent surface (agent loop, streaming LLM provider, fast Rust-backed tools) on the
BEAM, and leans on hot code loading to make the running app self-modifiable: tools, providers,
prompts, workflows, hooks, and UI pages are ETS-backed registries the agent can write at
runtime — even inside the packaged `.app`.

Design doc: [`architecture.md`](architecture.md). Delivery plan: [`plan.md`](plan.md).
Self-extension guide (for the agent and humans): [`guide.md`](guide.md).

## Umbrella apps

| App | What it is |
| --- | --- |
| `apps/catalyst` | Headless agent core: loop, sessions, tools, permissions/hooks, LLM providers, extensions. **No Phoenix dep.** |
| `apps/catalyst_web` | Phoenix LiveView UI: catch-all `ShellLive`, chat + extensions pages, UI registries, web self-mod tools. |
| `apps/catalyst_desktop` | Native desktop shell (elixir-desktop/wx) wrapping `catalyst_web`. |
| `apps/catalyst_cli` | Headless (no-wx) release, Burrito-capable — proves packaged hot-loading. |

Dependency arrows only point downward: `catalyst_desktop` → `catalyst_web` → `catalyst`.
The core never references `catalyst_web`; web-only extension kinds are dispatched through
`:persistent_term`.

## Running

- `mix phx.server` — develop the LiveView in a normal browser (fastest loop).
- `CATALYST_DESKTOP=1 iex -S mix` — boot the native wx window against the dev endpoint.
- `MIX_ENV=prod mix release catalyst_desktop` — packaged macOS `.app`/`.dmg` (see
  `architecture.md` §8).

## Workflow

When done with changes, run both and fix anything they raise:

```sh
mix precommit   # warnings-as-errors compile, unused-deps check, format, tests
mix dialyzer
```

Test tiers beyond the default suite:

- `mix test.flex` — the serial `:flexibility` tier (also part of `mix test`/`mix precommit`):
  composes the runtime-extensibility seams in the live test VM and diffs against a suite-wide
  baseline.
- `mix test.release` — opt-in: builds a temporary headless `catalyst_cli` release and proves
  packaged hot-loading, a scripted persisted session, `CATALYST_HOME` isolation, and
  crash-marker safe mode in fresh VMs.
