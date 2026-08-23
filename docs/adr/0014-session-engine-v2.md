# ADR-0014: Pure Session Engine V2

## Status

Accepted and implemented for the built-in session engine.

## Context

The first replaceable session-engine contract owned accepted-event reduction,
failure transcript repair, and quiescent snapshot/restore. The stable
`Session.Server` still mutated steering and follow-up queues directly, so the
contract did not yet describe a complete semantic state machine. Its unbounded
process-local snapshot map also lacked the capsule guarantees required for
long-lived managed generations.

Changing the V1 callbacks would silently break existing managed extensions.
Creating a second session-runtime hierarchy would instead split ownership of the
same process, transcript, and generation leases.

## Decision

`catalyst.session-engine/2` is an additional exact contract version for the
existing `agent.session_engine/default` service.

V2 implementations:

- initialize implementation-private state once per session;
- apply pure semantic commands;
- fold versioned events;
- return typed effects for the stable host to interpret;
- build failure and interrupted-tool repair messages;
- declare a state schema version;
- snapshot semantic plus private state;
- restore and verify a bounded state capsule.

`Session.Server` remains the single owner of GenServer messaging, run tasks,
transcript ordering, PubSub, provider resources, and runtime handles. It
validates every effect and interprets only the closed set defined by
`Catalyst.Session.Effect`.

The built-in engine uses V2. V1 claims remain valid and participate in the same
scope and priority resolution. When V1 is selected, the runtime supplies the
built-in pure command behavior while dispatching event and failure semantics
through the selected V1 implementation.

Handoff capsules:

- include exact source contract and implementation identity;
- carry a positive state schema version;
- reject PIDs, ports, references, and functions recursively;
- enforce a configurable serialized size bound;
- include a deterministic SHA-256 checksum;
- are verified before restore and before the old generation lease is released.

## Consequences

- Existing V1 session-engine extensions remain compatible.
- New engines can replace queue commands and event semantics without owning the
  session process.
- Effect execution stays observable, bounded, and host-controlled.
- Large or process-bound state fails handoff without changing the active engine.
- The local session factory remains a separate service; sovereign remote and
  distributed factories require a future transport contract.
