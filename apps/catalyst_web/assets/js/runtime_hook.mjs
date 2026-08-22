const STATE = Symbol("catalyst.runtimeHook");
const DIGEST = /^[0-9a-f]{64}$/;
const SEGMENT = /^[A-Za-z0-9][A-Za-z0-9._-]*$/;
const EXPORT = /^[A-Za-z_$][A-Za-z0-9_$]*$/;
const ENCODED_TRAVERSAL = /%(?:2e|2f|5c)/i;

const runtimeLocation = () => window.location;
const importModule = (url) => import(url);

const defaultReporter = (detail) => {
  console.error("[Catalyst RuntimeHook]", detail);
  window.dispatchEvent(
    new CustomEvent("catalyst:runtime-hook-error", { detail }),
  );
};

const errorDetail = (phase, state, error) => ({
  phase,
  source: state.source || null,
  export: state.exportName || null,
  name: error?.name || "Error",
  message: error?.message || String(error),
});

const reportError = (report, phase, state, error) => {
  report(errorDetail(phase, state, error));
};

const declaration = (hook) => {
  const source = hook.el.dataset.runtimeHookSrc;
  const exportName = hook.el.dataset.runtimeHookExport || "default";

  if (!EXPORT.test(exportName)) throw new Error("invalid runtime hook export");
  return { source, exportName };
};

export const runtimeModuleUrl = (source, location = runtimeLocation()) => {
  if (
    typeof source !== "string" ||
    source.length === 0 ||
    source.includes("\\") ||
    ENCODED_TRAVERSAL.test(source)
  ) {
    throw new Error("invalid runtime hook module URL");
  }

  const rawPath = source.split(/[?#]/, 1)[0];
  if (rawPath.split("/").some((segment) => segment === "." || segment === "..")) {
    throw new Error("invalid runtime hook module URL");
  }

  const base = new URL(location.href);
  const url = new URL(source, base);
  const segments = url.pathname.split("/").slice(1);
  const [prefix, digest, modules, ...modulePath] = segments;

  if (
    url.origin !== base.origin ||
    url.username ||
    url.password ||
    url.search ||
    url.hash ||
    prefix !== "runtime-assets" ||
    !DIGEST.test(digest || "") ||
    modules !== "modules" ||
    modulePath.length === 0 ||
    !modulePath.every((segment) => SEGMENT.test(segment)) ||
    !modulePath.at(-1).endsWith(".js")
  ) {
    throw new Error("invalid runtime hook module URL");
  }

  return url.href;
};

const invoke = async (hook, state, phase, report) => {
  const callback = state.runtime?.[phase];
  if (typeof callback !== "function") return;

  try {
    await callback.call(hook);
  } catch (error) {
    reportError(report, phase, state, error);
  }
};

const activate = async (hook, state, options) => {
  let selected;

  try {
    selected = declaration(hook);
    state.source = selected.source;
    state.exportName = selected.exportName;
    state.url = runtimeModuleUrl(selected.source, options.location());
  } catch (error) {
    reportError(options.report, "load", state, error);
    return;
  }

  const version = ++state.version;

  try {
    const namespace = await options.loadModule(state.url);
    if (state.destroyed || state.version !== version) return;

    const runtime = namespace[selected.exportName];
    if (runtime === null || !["object", "function"].includes(typeof runtime)) {
      throw new Error(`runtime hook export ${selected.exportName} was not found`);
    }

    state.runtime = runtime;
    await invoke(hook, state, "mounted", options.report);
  } catch (error) {
    if (!state.destroyed && state.version === version) {
      reportError(options.report, "load", state, error);
    }
  }
};

export const createRuntimeHook = (overrides = {}) => {
  const options = {
    loadModule: overrides.loadModule || importModule,
    location: overrides.location || runtimeLocation,
    report: overrides.report || defaultReporter,
  };

  return {
    async mounted() {
      const state = { version: 0, destroyed: false, runtime: null };
      this[STATE] = state;
      await activate(this, state, options);
    },

    async updated() {
      const state = this[STATE];
      if (!state || state.destroyed) return;

      let selected;
      try {
        selected = declaration(this);
      } catch (error) {
        reportError(options.report, "load", state, error);
        return;
      }

      if (selected.source === state.source && selected.exportName === state.exportName) {
        await invoke(this, state, "updated", options.report);
        return;
      }

      state.version += 1;
      await invoke(this, state, "destroyed", options.report);
      state.runtime = null;
      await activate(this, state, options);
    },

    async destroyed() {
      const state = this[STATE];
      if (!state || state.destroyed) return;

      state.destroyed = true;
      state.version += 1;
      await invoke(this, state, "destroyed", options.report);
      state.runtime = null;
    },
  };
};

export const RuntimeHook = createRuntimeHook();
