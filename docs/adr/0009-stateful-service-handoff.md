# ADR-0009: Stateful Service Handoff

## Status

Accepted for incremental implementation.

## Context

Replacing a module does not migrate the state held by a long-lived OTP process.
Sessions and mounted workbenches may retain structs, queues, tasks, documents,
and generation leases after a new implementation becomes active. Switching a
global pointer while such state is live would mix implementations or lose work.

## Decision

Stateful service contracts declare explicit, versioned snapshot and restore
callbacks. The stable host owns quiescence, validates a bounded capsule, pins the
candidate generation, restores the candidate, and only then swaps handles. The
old handle is released after the successful swap. Failed snapshot, validation,
or restore leaves the old implementation active and releases the candidate.

Session-engine handoff is allowed only while the session has no active run,
queued prompt, or pending tool batch. Workbench handoff rejects outstanding host
effects. Capsules are contract-specific; arbitrary process state, PIDs, sockets,
and Phoenix socket internals are not portable state.

Generic manifest migrations remain fail-closed unless their target service has
an implemented handoff coordinator. `:new_instances_only` declarations require
no state callback and may activate immediately. A graph-pointer rollback does
not claim to reverse a forward-only state migration.

## Consequences

- Existing sessions and mounts remain generation-consistent.
- Stateful upgrades can be tested independently from graph activation.
- Services without a migration protocol continue on their old generation or
  apply only to new instances.
- Future durable migrations must declare whether rollback is reversible,
  snapshot-reversible, forward-only, or limited to new instances.
