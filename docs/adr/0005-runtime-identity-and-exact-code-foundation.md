# ADR-0005: Runtime Identity and Exact-Code Foundation

## Status

Accepted. Service-only loader integration is available by explicit opt-in.

## Context

The first managed runtime used one deterministic candidate digest as all of:

- normalized graph identity;
- active generation identity;
- candidate process-tree identity;
- lease identity.

That conflation prevented a composition from being activated again while an
older activation of the same graph was still draining. It also left no durable
way to distinguish a service's logical module from the physical module carrying
the exact code selected by a pinned handle.

Exact-code retention needs three different identities:

1. what the declared graph means;
2. one attempt to activate that graph;
3. the compiled code artifact that supplies execution targets.

## Decision

### Graph identity

`Catalyst.Runtime.GenerationId` remains the deterministic SHA-256 identity of a
normalized candidate graph. The digest excludes parent activation identity and
physical implementation targets. Equal logical declarations therefore produce
the same graph identity.

### Activation identity

`Catalyst.Runtime.ActivationId` uniquely identifies each staging/publication
attempt. Candidate process trees, leases, active pointers, and lifecycle records
use activation identity. Activating the same graph twice creates two distinct
activation records and process trees.

### Artifact identity

`Catalyst.Runtime.ArtifactId` identifies one compilation artifact independently
of graph and activation identity. `Runtime.ArtifactSet` maps logical modules to
artifact-qualified physical modules and retains their accepted BEAM binaries.

### Logical and physical implementations

`Runtime.ImplementationRef` separates:

- `logical` — graph identity, configuration, and stable diagnostics;
- `target` — the concrete module or endpoint invoked by a handle;
- `artifact` — the supplying artifact, when applicable;
- `transport` — currently `:local`.

Candidate and manifest digests use the logical representation. A
`Runtime.Handle` exposes both logical identity and the pinned execution target.
The `agent.run_engine` adapter dispatches through that target.

### Compiler prototype

`Catalyst.Extensions.GenerationCompiler` compiles only explicitly opted-in
`code: :generation` API-v2 sources. It:

- parses one source file;
- rejects nested or dynamic module definitions;
- rejects known module-emitting forms such as protocols and implementations;
- assigns an artifact-specific physical namespace;
- rewrites fully qualified and ordinary aliased references among top-level
  modules in the file;
- compiles the rewritten AST;
- rejects and cleans every emitted module not represented by the artifact
  mapping;
- records logical-to-physical module mappings;
- binds artifact-local service implementations to `ImplementationRef`.

`Runtime.Artifacts` registers compiled sets as pending, attaches them to a
candidate activation before process staging, and retains them while any active
or retiring activation refers to them. Rejection and cancellation release
unattached artifacts. Fail-closed deactivation prevents new leases but retains
artifacts held by surviving runs until their final lease drains. Artifact and
lease records survive coordinator restarts so recovery does not purge code under
those runs. The loader's legacy module-version stack does not own
generation-qualified modules.

Artifact IDs include a source/compiler fingerprint and, when present, the exact
external data-manifest bytes. Byte-identical reloads reuse the same physical
namespace and active composition instead of minting new module atoms and
activations. Distinct source or manifest data receives a distinct artifact.

Because module names are permanent atoms in a running VM, the local compiler
reserves every distinct artifact namespace before it constructs physical module
names. A configurable VM-lifetime budget bounds that namespace set and rejects
new source once exhausted. Reusing an existing artifact does not consume the
budget. High-churn compilation still belongs on a disposable peer node or
external worker, where terminating the worker reclaims its atom table.

This first integrated path accepts service declarations only. Artifact-bound
extension points, contributions, processes, health checks, and migrations are
rejected with tagged errors rather than receiving incomplete lifecycle
guarantees.

## Consequences

- The same logical graph may be active and retiring in separate activations.
- A pinned old run and a new run may carry distinct exact physical targets.
- Persisted workflow selection remains logical; physical target names are
  runtime artifact data.
- Candidate graph identity no longer changes merely because its parent
  activation changed.
- Runtime diagnostics can display graph, activation, artifact, logical
  implementation, and physical target independently.
- Process-subtree or runtime-coordinator failure cannot revoke a surviving run's
  lease or purge its physical target.

## Remaining Work

- Bind artifact-local extension points, contributions, processes, health checks,
  and migrations through typed implementation references.
- Decide drain deadlines and forced-retirement policy.
- Generalize implementation-target dispatch beyond `agent.run_engine`.
- Eliminate transient main-VM compile side effects by staging compilation on a
  disposable peer node. The trusted local compiler validates and rolls back
  emitted modules, but macros execute before post-compile validation.
- Define cross-node implementation references and invocation transport.

## Rejected Alternatives

### Keep using the graph digest as the activation ID

This aliases separate lifecycles whenever the same graph is reactivated and can
replace a still-leased process tree.

### Put the physical module only in claim metadata

Metadata does not establish a typed dispatch contract and is too easy for
consumers to bypass.

### Put generation-qualified modules in the legacy owner version stack

The legacy stack replaces and purges source modules at file reload boundaries.
That would remove modules still held by leased handles. Artifact modules
therefore have an independent activation-aware owner.
