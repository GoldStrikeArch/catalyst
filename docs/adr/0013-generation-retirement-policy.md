# ADR-0013: Generation Retirement Policy

## Status

Accepted.

## Context

ADR-0004 retains a superseded or failed runtime generation while an in-flight
operation owns a lease. ADR-0005 ties generation-qualified code artifacts to
that activation lifetime. Those guarantees intentionally allow a stuck lease
owner to retain a process subtree and exact code indefinitely.

Products need an explicit choice between preserving in-flight work and placing
a bound on retained generations. Operators also need a deliberate recovery
operation instead of having purge logic silently revoke leases.

## Decision

1. Runtime-generation retirement is configured through
   `:runtime_generation_retirement`.
2. The policy has a non-negative `:drain_timeout` in milliseconds, or
   `:infinity`, and an `:on_timeout` action of `:retain` or `:cancel_owners`.
3. The default is `drain_timeout: :infinity, on_timeout: :retain`.
4. The legacy `:runtime_generation_drain_timeout` setting remains compatible
   and retains its former cancel-on-timeout behavior.
5. A finite deadline is recorded when an active generation starts retiring or
   fails closed.
6. Under `:retain`, an overdue generation remains visible and intact until its
   leases drain or an operator explicitly forces retirement.
7. Under `:cancel_owners`, the coordinator terminates processes holding leases.
   Their monitors release the leases; only then may cleanup stop the subtree and
   purge its artifact activation.
8. `Runtime.force_retire_generation/1` provides the same destructive transition
   explicitly. It rejects active, already retired, and unknown generations.
9. Forced retirement never deletes lease records optimistically. Process
   monitors remain the authority proving that old code is no longer executing.
10. Retired, rejected, and fully failed generation history is bounded by
    `:runtime_generation_history_limit`, defaulting to 100 terminal records.
    Active, retiring, and not-yet-drained failed records are never pruned.
11. Runtime introspection reports the deadline, timeout observation, forced
    retirement timestamp, status, and current lease count.

## Consequences

- The safe default favors completion and debuggability over bounded retention.
- Products with strict resource bounds can opt into cancellation without
  weakening the no-purge-while-running invariant.
- Explicit force retirement is destructive and may terminate sessions, runs,
  mounts, or other processes that own generation-pinned handles.
- Generation history cannot grow without bound after terminal transitions.
- This policy governs local process-owned leases. Future remote workers require
  an equivalent cancellation acknowledgement before artifact release.
