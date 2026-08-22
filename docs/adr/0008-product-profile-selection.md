# ADR-0008: Product Profile Selection

## Status

Accepted for incremental implementation.

## Context

Registries currently combine lookup mechanics with the default coding-agent
composition. This makes a new product require changes to mechanism code and
encourages premature OTP-application splitting. Catalyst also needs a small,
durable profile pointer that an eventual external Recovery Host can inspect
without evaluating extension code or converting user input to atoms.

## Decision

A product profile is a compiled module with a stable string id and explicit
initial composition callbacks. `Catalyst.Product.Default` owns the coding-agent
tool list; `Catalyst.Tools.Registry` owns only metadata validation, caching, and
lookup.

The host maintains an allow-list of stable profile ids to compiled modules.
Persistent selection stores only an id below `CATALYST_HOME`. Unknown, malformed,
or unavailable ids fall back to the default coding-agent profile. No atom or
module name is constructed from file content.

Changing the persisted selection returns `{:ok, :restart_required}`. Catalyst
does not attempt a partial live product switch while supervisors, sessions, and
host adapters from the old profile remain active. An explicit application
configuration module takes precedence for tests and fixed releases.

## Consequences

- Products own initial choices while Runtime Graph claims own later overlays.
- A minimal CLI or IDE profile can be added without editing registry mechanics.
- The profile pointer is suitable for a future launcher/recovery ABI.
- Profiles remain modules inside the existing application until independent
  dependencies, supervision, release selection, or publishing justify a physical
  pack split.
