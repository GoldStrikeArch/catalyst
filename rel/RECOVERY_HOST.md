# External Recovery Host

`rel/recovery_host` is a small process supervisor outside the Catalyst VM. It
starts one release command, waits for the VM's boot-readiness handshake, and
retries one failed boot with the last-known-good product profile and
`CATALYST_SAFE_MODE=1`.

```sh
rel/recovery_host start -- ./bin/catalyst_desktop start
rel/recovery_host select ide
rel/recovery_host diagnostics
rel/recovery_host stop
```

The native macOS launcher uses this host when it is present beside the bundle's
generated `run` script. Other release formats keep their existing entrypoints
and may opt in by invoking the host explicitly.

## Stable file protocol

The host owns these mode-`0600`, atomically replaced files below
`$CATALYST_HOME/recovery`:

| File | Bounded content |
|---|---|
| `boot_status` | lifecycle, boot token, profile, deadline, and safe-mode flag |
| `last_known_good_profile` | stable profile id from the last ready boot |
| `safe_mode` | `0` or `1` |
| `child_pid` | current child OS pid |
| `ready` | readiness token and effective product id written by the child VM |
| `stop_requested` | transient operator-stop marker that suppresses retry |

The active profile pointer remains `$CATALYST_HOME/product_profile`, shared
with Catalyst's existing profile selection. File inputs are limited to 1024
bytes; profile ids are limited to 128 lowercase ASCII identifier characters.

For each attempt the host exports `CATALYST_RECOVERY_READY_PATH` and
`CATALYST_RECOVERY_BOOT_TOKEN`. Catalyst atomically writes
`<token>:<effective-product-id>` only after normal extension loading survives
its stabilization window, or after a safe-mode bootstrap completes. The host
rejects a ready signal whose effective allow-listed product differs from the
requested profile. A missing or mismatched token, child exit, or deadline
expiry is a failed boot.

The host creates a missing recovery directory with mode `0700`. It never
changes permissions on an existing directory supplied through `--state-dir`.

## Boundary and limitations

This protects against an ordinary child VM boot failure because the profile
pointers and watchdog process live outside that VM. It is not a security
sandbox, does not survive deletion of its state by trusted in-process code,
does not update releases, and does not recover resource exhaustion of the host
OS. PID-based `stop` assumes the private recovery directory has not been
tampered with. The shell host supervises one local child; distributed or
multi-instance coordination requires a stronger launcher protocol.
