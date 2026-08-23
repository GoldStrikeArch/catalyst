# ADR-0010: Replaceable Workbench Host

## Status

Accepted as the web/IDE migration boundary.

## Context

Phoenix owns a compiled endpoint, router, session pipeline, root layout, and
LiveView socket lifecycle. Delegating an unrestricted socket to runtime code
would make lifecycle, uploads, navigation, reconnects, and state replacement
impossible to validate. At the same time, Catalyst needs a replaceable UI root
capable of hosting chat and IDE compositions.

## Decision

A stable `WorkbenchHostLive` owns the Phoenix socket and pins one
`ui.workbench/<slot>` Runtime Graph handle for the mount lifetime. `/` resolves
the `chat` slot, `/ide` resolves `default`, and `/workbench/:workbench` exposes
an explicit slot URL. A Workbench is a pure state/effects protocol: it receives
bounded events and context, returns JSON-serializable state plus validated
effects, and identifies a registered function-component render target. The host
owns forms, navigation, authentication, sessions, filesystem and command effects,
task supervision, and permission-broker calls.

Legacy Workbenches identify renderers by string ID. The host captures the
effective `UI.Registry` descriptor once at mount or remount and never resolves
it during later renders. An artifact-backed managed Workbench may instead
return `{module, function}` only when `module` is the exact physical local
implementation retained by its Runtime Handle and generation lease. Built-in,
imperative, process, external-worker, and raw implementations use the legacy
ID path unless a later contract defines a separately pinned renderer artifact.

Runtime replacements use the state-handoff protocol in ADR-0009. Workbench
effects are bounded and request IDs are unique per transition. Browser behavior
uses the single packaged `RuntimeHook` and same-origin, digest-addressed modules
from ADR-0007.

The contract's 256 MiB serialized-state bound is an emergency rejection ceiling,
not a recommended state size. Product Workbenches must define substantially
smaller projection budgets. Chat projects a bounded recent transcript window,
keeps the complete transcript in the session store, sends bounded streaming
deltas directly to the browser, and refreshes authoritative state at lifecycle
boundaries rather than once per token.

The replaceable chat Workbench is the default `/` product. The previous
`ShellLive` chat remains available at `/legacy-chat` as a recovery and parity
surface during this release cycle; registry-backed legacy pages remain under
`/:page`. Raw BEAM replacement remains the unrestricted escape hatch; it does
not receive managed Workbench guarantees.

## Consequences

- Runtime UI code cannot mutate arbitrary host socket state through the managed
  contract.
- The IDE can evolve as a composition without expanding `ShellLive`.
- Endpoint, router, CSRF/session machinery, and the stable host remain web-host
  boundaries until a controlled restart replaces them.
- Chat was moved into the Workbench as an explicit migration, not a wrapper
  around the existing LiveView; the legacy route makes rollback and parity
  comparison possible without changing the runtime graph.
