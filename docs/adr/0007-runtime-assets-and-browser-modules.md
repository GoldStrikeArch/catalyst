# ADR-0007: Runtime Assets and Browser Modules

## Status

Accepted.

## Context

Installed macOS application bundles are immutable in normal operation. Rebuilding
CSS or JavaScript into the release's `priv/static` directory therefore fails for
the exact packaged environment where self-extension matters most. LiveView also
fixes its named hook table when `LiveSocket` is constructed, so a runtime IDE pack
cannot add arbitrary hook names after boot.

## Decision

Catalyst seeds an editable asset source workspace below `CATALYST_HOME` and
publishes successful builds as immutable content-digest generations under
`runtime-assets`. CSS, the sole `app.js` bundle, and optional
`assets/runtime/**/*.js` modules participate in one digest. An atomic `current`
pointer exposes the complete generation; a failed build leaves the prior pointer
unchanged.

Runtime JavaScript is served only from same-origin, digest-addressed module URLs.
Publication and serving reject traversal, unsafe path segments, non-JavaScript
files, and symlinks. The packaged `app.js` pre-registers one `RuntimeHook`. A
LiveView element supplies a validated module URL and optional export name through
data attributes. The hook forwards mount, update, and destroy lifecycle, cancels
stale imports, tears down replaced modules, and reports structured browser errors.

The packaged CSS and JavaScript remain the fallback when no runtime generation is
active.

## Consequences

- Runtime UI changes never require a writable application bundle.
- Browser code remains covered by the existing `app.js`/`app.css` release model.
- A pack can add browser behavior without rebuilding the named LiveView hook map.
- Module generation changes can require a LiveView patch or browser reload; they
  do not imply arbitrary router or endpoint replacement.
- Old generations may be retained later while mounted workbench handles drain.
