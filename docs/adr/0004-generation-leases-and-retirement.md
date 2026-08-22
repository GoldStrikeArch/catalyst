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
8. Safe-mode clearing and active-generation failure remove the generation from
   new resolution immediately, but do not revoke leases owned by surviving
   operations. Failed generations retain exact-code artifacts until those leases
   drain.
9. Generation introspection reports lifecycle status and current lease count.
10. `agent.run_engine` is the first consumer. A session run owns a `:run` lease
    from successful `RunContext` construction through the supervised run-task
    boundary.

## Guarantee Boundary

This decision retains activation lifecycle and candidate-owned processes. It
does **not** by itself guarantee exact old BEAM code:

- ordinary managed modules still use their source module names;
- loading a replacement may install new code under the same name;
- raw trusted module shadowing remains immediate and opaque;
- drain deadlines and forced retirement are governed by ADR-0013.

ADR-0005 separates graph, activation, and artifact identities. Explicitly
opted-in API-v2 service implementations now use generation-qualified physical
modules whose artifact lifetime follows these leases. Ordinary managed modules,
raw overrides, and declaration kinds not yet bound through implementation
references retain the weaker guarantee above.

## Consequences

- New runs select the active generation while old leased runs may finish against
  a retiring generation's process resources.
- Crashed, killed, or cancelled run tasks cannot permanently leak leases.
- Preview and explanation calls remain lightweight because they do not acquire
  leases.
- The generation coordinator and lease server form separate supervision
  responsibilities: coordination serializes transitions; the lease server owns
  monitors and persists the minimal lease records needed to rebuild them.
- Restarting the artifact or lease server restarts the coordinator and extension
  loader through the existing `:rest_for_one` supervision group. New resolution
  fails closed while surviving lease owners retain their exact code until normal
  release or owner exit.
