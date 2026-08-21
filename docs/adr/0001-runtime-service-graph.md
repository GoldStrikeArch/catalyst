# ADR-0001: Runtime Service Graph

## Status

Accepted for incremental implementation.

## Context

Catalyst already resolves tools, providers, workflows, prompts, context policy,
hooks, and UI contributions through specialized owner-aware registries. These
registries intentionally retain separate storage, validation, and failure
domains, but they all express variants of the same semantic operation:

> An owner supplies an implementation or contribution for a logical capability,
> and the host selects the effective value at a documented binding boundary.

The project intends to remain self-modifiable. The built-in agent loop and
future session, persistence, permission, workbench, and IDE systems must be
replaceable without turning arbitrary dynamic dispatch into the default for
ordinary implementation code.

## Decision

Catalyst will introduce a process-free Runtime Service Graph semantic model:

- `ServiceKey` identifies a logical service and named slot.
- `ContractRef` identifies the required versioned public contract.
- `Scope` constrains claims to explicit runtime identity dimensions.
- `Claim` describes an owner's implementation, binding lifetime, health, and
  provenance.
- `Resolver` deterministically selects one effective claim and retains an
  explanation of hidden and rejected candidates.
- `Resolution` pins logical selection data at a binding boundary.

The Runtime Graph is not one global GenServer or one mandatory ETS table.
Existing registries remain authoritative during migration and expose adapters
into the shared semantic model.

Extension points are also data rather than a closed list of API functions.
Host subsystems declare schema-aware points with stable `{module, function}`
activation handlers. Extensions may define declarative points, contribute
owner-scoped values, and claim services. Definitions and generic entries use
process-free storage; concrete host handlers keep execution in the existing
specialized registries and failure domains.

Removing a point owner hides dependent generic entries but does not delete
entries owned by other extensions. Reintroducing a compatible point reactivates
them. Graph visibility alone does not imply execution activation: a subsystem
must consume Runtime Graph resolution or provide an activation handler.

The first production adapter is `agent.run_engine`. Existing
`Catalyst.Workflow.Registry` writes and compatibility APIs remain unchanged.
`Catalyst.Agent.Loop` is represented as an ordinary built-in claim.

Host applications register read-model adapters as stable `{module, function}`
pairs. `Catalyst.Runtime.snapshot/1` aggregates those adapters without creating a
core dependency on optional hosts such as `catalyst_web`. Every source reports
its health and coverage metadata; an unavailable source is not represented as an
intentionally empty registry.

Equal-ranked managed claims are ambiguous by default. Installation order is not
a universal precedence rule. Extension points may define other conflict
semantics explicitly in later phases.

## Guarantees

Phase-one `Resolution` values pin logical selection and diagnostics only. They
are not leases and do not delay extension module purge.

Future activation work will distinguish:

1. in-process managed activation, which can make graph visibility atomic;
2. isolated managed activation, which can also isolate compilation and setup;
3. raw trusted BEAM overrides, which retain maximum power with reduced
   transactional guarantees.

No in-process permission or recovery mechanism is described as a sandbox
against trusted extension code.

## Consequences

- Current behavior and extension APIs remain compatible.
- Run diagnostics gain stable service, contract, owner, scope, binding,
  provenance, and graph snapshot identity.
- Scope dimensions require real identities; a cwd is not silently promoted to a
  permanent workspace ID.
- Exact-code retention, process-owned leases, state handoff, candidate
  generations, and physical application extraction remain separate later
  decisions.
