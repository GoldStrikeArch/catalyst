# ADR-0003: Transactional Generation Activation

## Status

Accepted for incremental implementation.

## Context

ADR-0002 introduced inert API-v2 manifests and deterministic candidate planning.
Loading a v2 extension deliberately stopped at `:planning_only`; no manifest
declaration changed the active runtime.

Catalyst now needs a managed activation boundary that can stage a complete
composition, start candidate-owned processes, verify health, and publish all
declarative graph entries together. A failed candidate must leave the prior
generation visible and running.

API-v1 setup and raw BEAM replacement remain trusted imperative escape hatches.
They cannot inherit guarantees that depend on declarative planning.

## Decision

`Catalyst.Runtime.Generations` serializes managed API-v2 composition changes.
Its composition is keyed by extension source owner, while manifest IDs remain
the owners of claims and contributions inside the Runtime Graph. Installing or
removing one source owner rebuilds the candidate from every remaining v2
manifest.

Candidate staging runs in supervised task work outside the coordinator:

1. build the full candidate against host and API-v1 extension points;
2. reject claim and contribution conflicts with active imperative entries;
3. start a temporary candidate-owned `DynamicSupervisor`;
4. start every declared child with a bounded wait;
5. run every declared health check with its own timeout;
6. return the ready candidate to the coordinator.

Only after all steps succeed does `GenerationStore.publish/2` replace one
immutable persistent-term snapshot. Runtime Graph readers therefore observe the
old managed points, claims, and contributions or the complete new set, never a
partially published managed candidate.

The previous candidate process subtree remains alive until publication
completes. This ADR originally stopped it immediately afterward. ADR-0004
supersedes that lifecycle rule: a leased superseded generation now retires only
after its final handle is released. A rejected candidate's subtree is stopped
before the error is returned.

The first execution consumer is `agent.run_engine`. New run resolution combines
active generation claims with existing workflow layers and returns generation
provenance in run diagnostics. Other handler-backed extension points remain
visible in the generic Runtime Graph until their owning subsystem adopts managed
graph resolution; activation does not imperatively replay their legacy handlers.

Extension loading changes from `:planning_only` to `:active` only after the
generation coordinator publishes the candidate. API-v2 `setup/1` and
`metadata/0` callbacks are still never invoked.

## Failure and Recovery Semantics

- Build, dependency, collision, process-start, health-check, and timeout
  failures leave the prior active pointer unchanged.
- Concurrent activation attempts are rejected with a tagged
  `:generation_activation_in_progress` error.
- A candidate whose parent is no longer active is rejected before publication.
- Uninstall and disable rebuild the composition without the removed source
  owner. A failed disable activation restores the enabled source filename.
- A generation-coordinator restart fails closed: candidate processes and the
  active managed snapshot are cleared. `Catalyst.Extensions`, ordered after the
  coordinator in the `:rest_for_one` runtime group, recompiles enabled sources
  and reconstructs the composition.
- The coordinator monitors the active candidate process root. If that root exits,
  the matching generation is marked failed and its managed graph is immediately
  removed from resolution.
- Safe mode explicitly clears managed generations and candidate processes.

## Scope of Atomicity

This phase provides atomic **logical graph publication** for API-v2 declarations.
It does not provide atomic VM code replacement:

- source compilation still loads BEAM modules before candidate publication;
- identical module names are not generation-scoped;
- active operations did not yet hold lifecycle leases when this ADR was adopted;
- the previous generation was not yet retained for draining;
- candidate processes may perform side effects while staged;
- health checks are trusted in-process callbacks whose arbitrary side effects
  are not rolled back; checks must be bounded and idempotent;
- API-v1 registry handlers remain imperative and independently visible.

Those limitations are explicit rather than hidden behind a stronger
transactionality claim.

## Deferred Work

- artifact binding beyond service implementations for the generation-qualified
  loader introduced by ADR-0005;
- drain deadlines, forced retirement, and delayed module purge beyond the
  lifecycle leases introduced by ADR-0004;
- post-activation rollback to a retained process generation;
- state capsules, migrations, and session handoff;
- isolated compilation and staging on a peer node or external worker;
- durable last-known-good generation storage owned by the Recovery Host;
- managed execution adapters for tools, providers, permissions, and UI.

## Consequences

- API-v2 extensions can replace the default run engine without executing
  imperative setup.
- Process and health failures are rejected before graph visibility changes.
- Multiple v2 source files compose into one generation instead of overwriting
  one another.
- Runtime introspection can report active, retired, and rejected generations.
- The existing extension loader remains responsible for source, module, and
  owner rollback around generation activation.
- Lifecycle continuity is defined by ADR-0004. Exact-code identity, service-only
  artifact retention, and its remaining extension boundaries are defined by
  ADR-0005.
