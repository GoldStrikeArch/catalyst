import assert from "node:assert/strict";
import test from "node:test";

import {
  createRuntimeHook,
  runtimeModuleUrl,
} from "../../assets/js/runtime_hook.mjs";

const digest = "a".repeat(64);
const modulePath = `/runtime-assets/${digest}/modules/editor/main.js`;
const location = () => ({ href: "https://catalyst.test/chat" });

const context = (hook, source = modulePath, exportName = undefined) => {
  const dataset = { runtimeHookSrc: source };
  if (exportName) dataset.runtimeHookExport = exportName;
  return Object.assign({ el: { dataset } }, hook);
};

test("accepts only same-origin digest-addressed JavaScript modules", () => {
  assert.equal(
    runtimeModuleUrl(modulePath, location()),
    `https://catalyst.test${modulePath}`,
  );
  assert.equal(
    runtimeModuleUrl(`https://catalyst.test${modulePath}`, location()),
    `https://catalyst.test${modulePath}`,
  );

  for (const source of [
    `https://outside.test${modulePath}`,
    "/runtime-assets/not-a-digest/modules/editor/main.js",
    `/runtime-assets/${digest}/modules/../app.js`,
    `/runtime-assets/${digest}/modules/%2e%2e/app.js`,
    `/runtime-assets/${digest}/modules/editor/main.mjs`,
    `${modulePath}?cache=off`,
    `${modulePath}#fragment`,
  ]) {
    assert.throws(() => runtimeModuleUrl(source, location()));
  }
});

test("forwards the LiveView mount, update, and destroy lifecycle", async () => {
  const calls = [];
  const hook = createRuntimeHook({
    location,
    report: (error) => calls.push(["error", error]),
    loadModule: async () => ({
      default: {
        mounted() {
          calls.push(["mounted", this.el.dataset.runtimeHookSrc]);
        },
        updated() {
          calls.push(["updated", this.el.dataset.runtimeHookSrc]);
        },
        destroyed() {
          calls.push(["destroyed", this.el.dataset.runtimeHookSrc]);
        },
      },
    }),
  });
  const liveHook = context(hook);

  await liveHook.mounted();
  await liveHook.updated();
  await liveHook.destroyed();

  assert.deepEqual(calls, [
    ["mounted", modulePath],
    ["updated", modulePath],
    ["destroyed", modulePath],
  ]);
});

test("replaces a changed module after destroying the prior runtime", async () => {
  const calls = [];
  const second = `/runtime-assets/${"b".repeat(64)}/modules/editor/main.js`;
  const hook = createRuntimeHook({
    location,
    report: (error) => calls.push(["error", error]),
    loadModule: async (url) => ({
      default: {
        mounted() {
          calls.push(["mounted", url]);
        },
        destroyed() {
          calls.push(["destroyed", url]);
        },
      },
    }),
  });
  const liveHook = context(hook);

  await liveHook.mounted();
  liveHook.el.dataset.runtimeHookSrc = second;
  await liveHook.updated();

  assert.deepEqual(calls, [
    ["mounted", `https://catalyst.test${modulePath}`],
    ["destroyed", `https://catalyst.test${modulePath}`],
    ["mounted", `https://catalyst.test${second}`],
  ]);
});

test("does not mount a module that resolves after the hook is destroyed", async () => {
  const calls = [];
  let resolveModule;
  const pendingModule = new Promise((resolve) => (resolveModule = resolve));
  const hook = createRuntimeHook({
    location,
    report: (error) => calls.push(["error", error]),
    loadModule: () => pendingModule,
  });
  const liveHook = context(hook);

  const mounted = liveHook.mounted();
  await Promise.resolve();
  await liveHook.destroyed();
  resolveModule({ default: { mounted: () => calls.push(["mounted"]) } });
  await mounted;

  assert.deepEqual(calls, []);
});

test("reports structured load and lifecycle errors", async () => {
  const errors = [];
  const hook = createRuntimeHook({
    location,
    report: (error) => errors.push(error),
    loadModule: async () => ({
      custom: {
        mounted() {
          throw new TypeError("broken mount");
        },
      },
    }),
  });
  const liveHook = context(hook, modulePath, "custom");

  await liveHook.mounted();
  liveHook.el.dataset.runtimeHookExport = "bad-name";
  await liveHook.updated();

  assert.deepEqual(
    errors.map(({ phase, source, export: exportName, name, message }) => ({
      phase,
      source,
      exportName,
      name,
      message,
    })),
    [
      {
        phase: "mounted",
        source: modulePath,
        exportName: "custom",
        name: "TypeError",
        message: "broken mount",
      },
      {
        phase: "load",
        source: modulePath,
        exportName: "custom",
        name: "Error",
        message: "invalid runtime hook export",
      },
    ],
  );
});
