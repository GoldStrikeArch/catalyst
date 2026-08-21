# ADR-0004: Generation Leases and Retirement

## Status

Accepted.

## Context

ADR-0003 introduced atomic managed-generation activation, but a successful
activation immediately stopped the previous candidate process subtree.
`Runtime.Resolution` recorded generation identity without retaining that
generation for an in-flight operation.

Long-running runs need a lifecycle pin so a newly activated composition can
serve new work without terminating process resources still used by old work.
Lease acquisition must also be serialized with publication; otherwise a caller
could validate the old active generation while the coordinator concurrently
publishes and retires it.

## Decision

1. Logical resolution remains process-free and does not itself retain anything.
2. Executing a managed service acquires a process-owned `Runtime.Lease` through
   `Runtime.Generations`.
3. `Generations` serializes acquisition with activation and rejects a resolution
   whose recorded generation is no longer active.
4. `Runtime.Leases` owns process monitors. Explicit release is preferred, while
   owner exit is the final cleanup guarantee.
5. A superseded generation becomes `:retiring`. New resolution never selects it.
6. A retiring generation's candidate process subtree remains alive while any
   lease exists.
7. Releasing the final lease retires the generation and stops its subtree.
8. Safe-mode clearing and active-generation failure may revoke leases
   immediately to preserve fail-closed recovery.
9. Generation introspection reports lifecycle status and current lease count.
10. `agent.run_engine` is the first consumer. A session run owns a `:run` lease
    from successful `RunContext` construction through the supervised run-task
    boundary.

## Guarantee Boundary

This decision retains generation lifecycle and candidate-owned processes. It
does **not** yet guarantee exact old BEAM code:

- managed modules still use their source module names;
- loading a replacement may install new code under the same name;
- raw trusted module shadowing remains immediate and opaque;
- there is no drain deadline or forced-retirement policy yet.

Exact code retention requires generation-qualified physical modules or an
isolated execution boundary. That work remains the next generation-runtime
milestone.

## Consequences

- New runs select the active generation while old leased runs may finish against
  a retiring generation's process resources.
- Crashed, killed, or cancelled run tasks cannot permanently leak leases.
- Preview and explanation calls remain lightweight because they do not acquire
  leases.
- The generation coordinator and lease server form separate supervision
  responsibilities: coordination serializes transitions; the lease server owns
  monitors.
- Restarting the lease server restarts the coordinator and extension loader
  through the existing `:rest_for_one` supervision group, rebuilding managed
  state fail closed.
