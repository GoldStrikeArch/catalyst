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
`ui.workbench/default` Runtime Graph handle for the mount lifetime. A Workbench
is a pure state/effects protocol: it receives bounded events and context, returns
JSON-serializable state plus validated effects, and identifies a registered
function-component render target. The host owns forms, navigation, filesystem
and command effects, task supervision, and permission-broker calls.

Runtime replacements use the state-handoff protocol in ADR-0009. Workbench
effects are bounded and request IDs are unique per transition. Browser behavior
uses the single packaged `RuntimeHook` and same-origin, digest-addressed modules
from ADR-0007.

The current chat `ShellLive` remains a compatibility product controller until a
separate chat-view/process contract can preserve its session and streaming
lifecycle. Raw BEAM replacement remains the unrestricted escape hatch; it does
not receive managed Workbench guarantees.

## Consequences

- Runtime UI code cannot mutate arbitrary host socket state through the managed
  contract.
- The IDE can evolve as a composition without expanding `ShellLive`.
- Endpoint, router, CSRF/session machinery, and the stable host remain web-host
  boundaries until a controlled restart replaces them.
- Moving chat into the Workbench is an explicit migration, not a wrapper around
  the existing LiveView.
