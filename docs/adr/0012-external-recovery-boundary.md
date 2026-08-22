# ADR-0012: External Recovery Boundary

## Status

Accepted for local release supervision.

## Context

An in-process extension can stop supervisors, halt the VM, mutate ETS, exhaust
resources, or load unsafe native code. A recovery process inside the same VM can
detect ordinary extension boot failures but cannot guarantee recovery from the
failure domain it supervises.

## Decision

The strong Layer-0 boundary is an external launcher. It communicates through a
small, bounded file protocol containing the requested product profile, boot
token, readiness status, safe-mode flag, child PID, and last-known-good profile.
The launcher starts one Catalyst VM, waits for a matching readiness handshake,
and retries a failed boot once in safe mode with the last-known-good profile.

The active product pointer contains a stable allow-listed string id, never a
module name or dynamically created atom. Replacing the meta-runtime itself uses
this boundary plus a controlled VM or release restart.

The current shell implementation is a local watchdog, not an updater, security
sandbox, distributed coordinator, or defense against host-level resource
exhaustion. Its exact protocol and operational constraints are documented in
`rel/RECOVERY_HOST.md`.

## Consequences

- Ordinary crash loops can be recovered outside the replaceable application VM.
- Safe mode and last-known-good selection survive a failed Catalyst boot.
- Trusted in-process code remains capable of damaging user-owned recovery files;
  stronger adversarial isolation requires operating-system controls.
- The recovery ABI stays intentionally smaller than any agent, session, pack,
  or UI contract.
