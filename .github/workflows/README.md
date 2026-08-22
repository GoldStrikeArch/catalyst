# Catalyst automation

## Pull requests and `main`

[`ci.yml`](ci.yml) runs four pull-request gates:

1. **Quality and tests** runs `mix precommit`, then checks that formatting or another task did not
   rewrite tracked files.
2. **Dialyzer** runs the project's required static analysis in its preferred `dev` environment.
3. **Headless release smoke test** runs `mix test.release`, which assembles and boots a plain
   `catalyst_cli` release in fresh VMs and exercises packaged hot-loading, persistence, path
   isolation, and safe mode.
4. **macOS production compile and assets** compiles the desktop umbrella on an Apple-silicon runner
   with warnings as errors and builds the minified Phoenix assets.

The recommended required checks for the `main` branch are all four jobs above. The workflows use
read-only repository permissions, cancel superseded CI runs, pin actions to commit SHAs, and key
BEAM caches by operating system, OTP, Elixir, purpose, and `mix.lock`.

Every push to `main` also starts three **Portable release** runners: Linux, Apple-silicon macOS, and
Windows. Each runner natively assembles the plain `catalyst_cli` OTP release with bundled ERTS,
boots that release in an isolated `CATALYST_HOME`, verifies a built-in tool, and runs the packaged
self-extension test. The matrix is also available through `workflow_dispatch`, but is skipped on
pull requests to avoid tripling routine PR cost.

This matrix deliberately tests the plain OTP release rather than the Burrito wrapper. Burrito does
not support building on a Windows host; the plain release is the common native artifact that can be
built and executed on all three hosted operating systems. The separate release smoke gate still
tests the deeper persisted-session and safe-mode contracts on Linux.

The toolchain tracks the versions used by current Catalyst development: Elixir 1.20 on OTP 29 in
GitHub Actions and local release validation.

## Desktop releases

[`release.yml`](release.yml) runs manually or for a `v*` tag on an Apple-silicon macOS runner. It:

- installs the four fast tools that must be embedded in the application;
- builds assets and the real `catalyst_desktop` release;
- verifies the native arm64 launcher, bundled tools, runtime asset workspace, served assets, and
  self-extension guide;
- preserves the `.app` resource metadata in a zip, collects generated installers, and writes
  SHA-256 checksums;
- uploads a 14-day workflow artifact; and
- creates or updates the GitHub release for a tag.

A release tag must equal `v<Mix.Project version>` (for example, `v0.1.0`). Manual runs build and
retain artifacts but do not publish a GitHub release.

The current packaging code ad-hoc signs native executables. Public distribution without macOS
Gatekeeper warnings will additionally require a Developer ID certificate, hardened runtime signing,
and Apple notarization. Those credentials and signing steps are intentionally not represented until
the project has an Apple Developer identity.

## Deliberately opt-in test tiers

Hosted CI does not run:

- `:live_wire`, because it sends real provider requests using a developer's credentials;
- `mix test.computer`, because it requires a logged-in GUI session plus Accessibility and Screen
  Recording grants; or
- `:clipboard`, because it destructively overwrites the real macOS pasteboard.

Run those tiers deliberately on an appropriately configured development machine.
