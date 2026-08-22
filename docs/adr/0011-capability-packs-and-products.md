# ADR-0011: Capability Packs and Product Composition

## Status

Accepted for incremental extraction.

## Context

Hard-coded provider, tool, process, asset, and release lists make registry
mechanisms responsible for product choices. Physically splitting every concept
into an OTP application before dependency inversion would instead create cycles
and forwarding facades.

## Decision

A capability pack is validated, declarative compiled data with a stable id,
version, trust class, host/platform constraints, dependencies, services, and
optional release contributions. A product profile selects an initial pack set
and product-owned tools. The pack registry validates dependencies, compatibility,
duplicates, and host/platform eligibility before startup or release assembly.

Registries own lookup and lifecycle mechanisms. Packs own capabilities and their
provenance. Products own the initial composition. Runtime extensions may overlay
that composition through ordinary scoped claims.

Pack extraction begins as cohesive namespaces and manifests inside the existing
umbrella applications. A separate OTP application is justified only by an
independent dependency set, supervision lifecycle, release selection, trust
boundary, or publishing/testing need.

## Consequences

- Minimal CLI, coding-agent, and IDE products can share the same meta-runtime.
- Release executables and future sidecars/assets have explicit owners and
  deterministic plans.
- Adding a provider family no longer requires generic web code to import it.
- Physical application extraction remains a later enforcement step rather than
  a prerequisite for semantic inversion.
