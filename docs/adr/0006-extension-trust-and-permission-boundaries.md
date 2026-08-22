# ADR-0006: Extension Trust and Permission Boundaries

## Status

Accepted for incremental implementation.

## Context

Catalyst supports source extensions compiled into the active BEAM VM. Such code
can invoke filesystem, process, networking, code-server, and operating-system
APIs directly. A replaceable permission policy can govern actions routed through
Catalyst, but it cannot constrain arbitrary code running in the same VM.

The runtime needs to describe this difference without presenting policy hooks as
a sandbox. Isolated workers and remote services therefore need an explicit
manifest identity and a matching invocation transport before resource brokers
can enforce capability grants.

## Decision

API-v2 manifests declare one of four trust classes:

- `:compiled_trusted` — release code reviewed and compiled with the product;
- `:local_trusted` — runtime source compiled into the Catalyst VM;
- `:isolated_worker` — code invoked through an external worker boundary;
- `:remote_service` — a service outside the local Catalyst runtime.

The compatibility default is `:local_trusted`. Both in-process classes are
reported as unrestricted. Declaring `:isolated_worker` or `:remote_service`
describes the required execution boundary; it does not create that boundary by
itself. Activation must reject a service whose declared trust class is
incompatible with its actual invocation transport once isolated transports are
introduced.

Activation rejects an isolated trust declaration unless the contract has a real
external transport. The first such vertical is `catalyst.permission-policy/1`:
source is compiled and executed only in a candidate-owned external Elixir VM,
and the host accepts only bounded, versioned permission decisions over its wire
protocol.

`agent.permission_policy/default` is resolved and pinned for each brokered tool
or Workbench action. It fails closed when resolution, execution, timeout, worker
death, or result validation fails. Existing tool hooks remain a secondary
product-policy gate.

## Guarantee Boundary

Permission decisions are enforceable only for actions that pass through a
Catalyst broker. A trusted in-process extension can bypass those brokers. The
external permission worker isolates VM crashes and host code loading, but still
runs as the Catalyst OS user. Strong filesystem/network/process enforcement
requires an OS sandbox or remote service with no direct access to host resources.

Human approval challenges must eventually identify a host-controlled channel;
an agent-readable file or ordinary tool call is not proof of human consent.

## Consequences

- Diagnostics can state accurately whether an extension is unrestricted.
- Products may refuse trust classes or capability escalations during activation.
- Broker contracts can be introduced one real resource at a time.
- Existing source extensions remain compatible and explicitly local trusted.
- Catalyst does not claim sandboxing until an external transport and resource
  boundary are both active.
