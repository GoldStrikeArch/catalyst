# ADR-0002: Declarative Manifests and Candidate Planning

## Status

Accepted for incremental implementation. The `:planning_only` loader lifecycle
described here is superseded by ADR-0003 after successful candidate staging.

## Context

API-v1 extensions execute arbitrary `setup/1` code while a load is being
committed. Owner tracking makes those effects reversible, but the host cannot
fully validate a multi-service change before the extension starts mutating
registries. This is appropriate for Catalyst's trusted imperative escape hatch,
but it cannot provide all-or-nothing activation for future replacements of
stateful services, process trees, or the workbench.

The next lifecycle needs an inert description of proposed services, extension
points, contributions, processes, health checks, migrations, and capabilities.
That description must be discoverable without calling extension-authored
functions. It must also be possible to validate and digest a complete proposed
graph without changing the active runtime.

## Decision

Generation-managed extensions may declare their authoritative manifest in an
adjacent `<source>.manifest.json` file. Catalyst size-bounds, parses, and
validates that file before source compilation, resolves implementation names
only against modules declared by the parsed source, and includes the exact
manifest bytes in artifact identity. This data-only path avoids executing
extension code merely to discover its proposed graph. The embedded `manifest/1`
macro remains supported for compatibility and trusted local development.

Catalyst introduces API-v2 extension manifests:

```elixir
defmodule MyExtension do
  use Catalyst.Extension, api: 2

  manifest %{
    id: "my-extension",
    version: "1.0.0",
    services: [],
    contributions: []
  }
end
```

The validated manifest and API version are persisted as BEAM attributes.
Discovery reads those attributes through module introspection. It does not call
`setup/1`, `metadata/0`, `manifest/0`, or another extension-authored discovery
callback. API-v2 metadata comes from the persisted manifest.

`Catalyst.Runtime.Candidate.Builder` is a pure planner. Given API-v2 manifests,
base-generation extension points, available dependency manifests, and an
optional parent identity, it:

- validates exact contract compatibility and declaration structure;
- normalizes schema-bound contribution payloads;
- rejects conflicts and process-local terms;
- produces claims, extension points, contributions, process declarations,
  health checks, migrations, capabilities, and provenance;
- computes a deterministic digest and candidate identity.

The builder does not read registries, invoke extension callbacks, load code,
start processes, execute health checks or migrations, publish a generation
pointer, or modify the active graph.

Compiling a v2 source file still uses Catalyst's existing trusted in-process
compiler and therefore loads its BEAM modules. Compilation is not a sandbox or
blue/green activation boundary.

During this phase, loading a v2 extension is explicitly `:planning_only`.
Catalyst tracks the compiled owner and exposes its manifest metadata, but it does
not activate manifest declarations. A later lifecycle change will stage the
candidate and atomically switch the active generation.

## Compatibility

API-v1 remains unchanged:

- modules using `use Catalyst.Extension` still implement `setup/1`;
- manually authored legacy modules exporting `setup/1` remain discoverable;
- tool-only files remain auto-registered;
- `metadata/0` remains bounded and crash-safe for API-v1 modules;
- raw BEAM shadowing remains available with its existing guarantees.

An API-v2 module is never sent through the API-v1 setup pipeline, even if it
exports a function named `setup/1`.

## Deferred Work

This decision does not introduce:

- an active-generation store or atomic pointer switch;
- owner process staging;
- execution of health checks or migrations;
- generation-scoped physical module names;
- handles, leases, drain, or delayed purge;
- state handoff;
- rollback to a parent generation;
- isolated compilation on a peer node or external worker.

Those require a separate transactional-activation decision.

## Consequences

- Distributable extensions can describe their intended runtime footprint before
  any managed activation occurs.
- Candidate planning is deterministic and independently testable.
- The loader can clearly distinguish imperative activation from declarative
  planning.
- Manifest declarations must use durable data. Functions, PIDs, ports, and
  references are rejected from candidate plans.
- API-v2 source remains trusted code because compilation itself executes compiler
  facilities in the host VM.
- Catalyst carries both extension modes: declarative managed evolution and an
  imperative Emacs-like escape hatch.
