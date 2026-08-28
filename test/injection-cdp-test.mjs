import { spawn } from "node:child_process";
import { mkdtemp, readFile, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";

const testDirectory = path.dirname(fileURLToPath(import.meta.url));
const source = await readFile(path.join(testDirectory, "../src/injected.js"), "utf8");
const profile = await mkdtemp(path.join(tmpdir(), "codex-injection-test."));
const child = spawn("/Applications/ChatGPT.app/Contents/MacOS/ChatGPT", [
  `--user-data-dir=${profile}`,
  "--remote-debugging-pipe",
  "--no-first-run",
], { stdio: ["ignore", "ignore", "ignore", "pipe", "pipe"] });

let nextId = 1;
let buffer = Buffer.alloc(0);
const pending = new Map();

child.stdio[4].on("data", chunk => {
  buffer = Buffer.concat([buffer, chunk]);
  for (;;) {
    const end = buffer.indexOf(0);
    if (end < 0) break;
    const raw = buffer.subarray(0, end).toString();
    buffer = buffer.subarray(end + 1);
    if (!raw) continue;
    const message = JSON.parse(raw);
    const callback = pending.get(message.id);
    if (callback) {
      pending.delete(message.id);
      callback.resolve(message);
    }
  }
});

function command(method, params = {}, sessionId) {
  const id = nextId++;
  const packet = Buffer.from(`${JSON.stringify({ id, method, params, ...(sessionId ? { sessionId } : {}) })}\0`);
  child.stdio[3].write(packet);
  return new Promise((resolve, reject) => {
    const timer = setTimeout(() => {
      if (pending.delete(id)) reject(new Error(`timeout: ${method}`));
    }, 12_000);
    pending.set(id, {
      resolve: value => {
        clearTimeout(timer);
        resolve(value);
      },
    });
  });
}

const banner = ({
  title = "You’re out of Codex and Work usage",
  message = "Upgrade for more now, or wait for usage to reset on tomorrow.",
  buttons = ["Upgrade", "Reset usage"],
} = {}) => `
  <aside class="relative isolate flex w-full overflow-hidden rounded-2xl border bg-surface py-2">
    <div aria-hidden="true"></div><div><svg></svg><div><h3><div><span>${title}</span><span>${message}</span></div></h3>
    <div>${buttons.map(label => `<button>${label}</button>`).join("")}</div></div></div>
  </aside>`;

const cases = [
  { name: "blocking banner hidden", html: banner(), decision: "hidden", hidden: 1 },
  {
    name: "screenshot banner hidden",
    html: banner({ message: "Your rate limit resets on Aug 27, 1:08 AM. Upgrade or use one of your rate limit resets now." }),
    decision: "hidden",
    hidden: 1,
  },
  {
    name: "image limit preserved",
    html: banner({ title: "You’re out of image generation usage", message: "Image usage resets tomorrow.", buttons: ["Dismiss"] }),
    decision: "absent",
    hidden: 0,
  },
  {
    name: "model limit preserved",
    html: banner({ title: "This model is out of usage", message: "Try another model.", buttons: [] }),
    decision: "absent",
    hidden: 0,
  },
  {
    name: "warning preserved",
    html: banner({ title: "You’re approaching your usage limit", message: "Usage resets tomorrow.", buttons: ["Dismiss"] }),
    decision: "absent",
    hidden: 0,
  },
  {
    name: "security warning preserved",
    html: banner({ title: "Full access is on", message: "This increases risk of data loss.", buttons: ["Don’t show again"] }),
    decision: "absent",
    hidden: 0,
  },
  {
    name: "similar exact title rejected",
    html: banner({ message: "This is unrelated.", buttons: ["Upgrade"] }),
    decision: "structure-rejected",
    hidden: 0,
  },
  {
    name: "error text preserved",
    html: banner({ message: "Couldn’t reset usage. Please try again.", buttons: ["Upgrade"] }),
    decision: "structure-rejected",
    hidden: 0,
  },
  {
    name: "unknown action fails closed",
    html: banner({ buttons: ["Continue"] }),
    decision: "structure-rejected",
    hidden: 0,
  },
  { name: "multiple candidates fail closed", html: banner() + banner(), decision: "ambiguous", hidden: 0 },
];

let output;
try {
  await new Promise(resolve => setTimeout(resolve, 1200));
  const created = await command("Target.createTarget", { url: "about:blank" });
  const targetId = created.result.targetId;
  const attached = await command("Target.attachToTarget", { targetId, flatten: true });
  const sessionId = attached.result.sessionId;
  await command("Runtime.evaluate", {
    expression: "document.body.innerHTML='<div id=\"root\"></div>';globalThis.__CODEX_LIMIT_BANNER_HIDER_TEST_MODE__=true;globalThis.__clicks=0;",
  }, sessionId);
  await command("Runtime.evaluate", { expression: source }, sessionId);

  const results = [];
  for (const test of cases) {
    const expression = `(() => {
      const root = document.querySelector('#root');
      root.innerHTML = ${JSON.stringify(test.html)};
      for (const button of root.querySelectorAll('button')) button.addEventListener('click', () => globalThis.__clicks++);
      globalThis.__codexLimitBannerHiderInstance.scan();
      return {
        status: globalThis.__codexLimitBannerHiderStatus,
        clicks: globalThis.__clicks,
        marked: root.querySelectorAll('aside[data-codex-limit-banner-hider=hidden]').length,
        visible: [...root.querySelectorAll('aside')].filter(element => getComputedStyle(element).display !== 'none').length,
      };
    })()`;
    const evaluated = await command("Runtime.evaluate", { expression, returnByValue: true }, sessionId);
    const actual = evaluated.result.result.value;
    const expectedVisible = (test.html.match(/<aside\b/gu) ?? []).length - test.hidden;
    const pass = actual.status.decision === test.decision &&
      actual.status.hiddenCount === test.hidden &&
      actual.marked === test.hidden &&
      actual.visible === expectedVisible &&
      actual.clicks === 0;
    results.push({ name: test.name, pass, expected: { decision: test.decision, hidden: test.hidden, visible: expectedVisible }, actual });
  }

  const performanceExpression = `(async () => {
    const root = document.querySelector('#root');
    const instance = globalThis.__codexLimitBannerHiderInstance;
    const resetMetrics = () => {
      for (const key of Object.keys(instance.metrics)) instance.metrics[key] = 0;
    };
    const yieldTask = () => new Promise(resolve => {
      const channel = new MessageChannel();
      channel.port1.onmessage = () => {
        channel.port1.close();
        channel.port2.close();
        resolve();
      };
      channel.port2.postMessage(null);
    });

    const fragment = document.createDocumentFragment();
    for (let index = 0; index < 10000; index += 1) {
      const element = document.createElement('div');
      element.textContent = 'node-' + index;
      fragment.append(element);
    }
    root.replaceChildren(fragment);
    const sidebar = document.createElement('aside');
    sidebar.className = 'sidebar-live';
    const sidebarText = document.createElement('span');
    sidebarText.append('sidebar');
    sidebar.append(sidebarText);
    root.append(sidebar);
    const streamContainer = root.firstChild;
    const streamTarget = streamContainer.firstChild;
    instance.scan();
    resetMetrics();
    const characterDataStartedAt = performance.now();
    for (let index = 0; index < 60; index += 1) {
      streamTarget.data = 'stream-' + index;
      await yieldTask();
    }
    await new Promise(resolve => setTimeout(resolve, 50));
    const characterDataStream = {
      elapsedMs: performance.now() - characterDataStartedAt,
      ...instance.metrics,
    };

    resetMetrics();
    const sidebarStartedAt = performance.now();
    for (let index = 0; index < 60; index += 1) {
      sidebarText.firstChild.data = 'sidebar-' + index;
      await yieldTask();
    }
    await new Promise(resolve => setTimeout(resolve, 300));
    const sidebarStream = {
      elapsedMs: performance.now() - sidebarStartedAt,
      ...instance.metrics,
    };

    resetMetrics();
    const childListStartedAt = performance.now();
    for (let index = 0; index < 60; index += 1) {
      const span = document.createElement('span');
      span.textContent = 'chunk-' + index;
      streamContainer.append(span);
      await yieldTask();
    }
    await new Promise(resolve => setTimeout(resolve, 300));
    const childListStream = {
      elapsedMs: performance.now() - childListStartedAt,
      ...instance.metrics,
    };
    const irrelevantStream = { characterDataStream, sidebarStream, childListStream };

    root.innerHTML = ${JSON.stringify(banner())};
    await new Promise(resolve => setTimeout(resolve, 1100));
    const discovery = {
      status: globalThis.__codexLimitBannerHiderStatus,
      hidden: root.querySelectorAll('aside[data-codex-limit-banner-hider=hidden]').length,
    };
    const messageTarget = root.querySelector('h3 span:last-child').firstChild;
    resetMetrics();
    const relevantStartedAt = performance.now();
    for (let index = 0; index < 60; index += 1) {
      messageTarget.data = 'Upgrade for more now, or wait for usage to reset on day-' + index + '.';
      await yieldTask();
    }
    await new Promise(resolve => setTimeout(resolve, 300));
    const relevantStream = {
      elapsedMs: performance.now() - relevantStartedAt,
      ...instance.metrics,
      status: globalThis.__codexLimitBannerHiderStatus,
      hidden: root.querySelectorAll('aside[data-codex-limit-banner-hider=hidden]').length,
    };
    return { irrelevantStream, discovery, relevantStream };
  })()`;
  const performanceEvaluated = await command("Runtime.evaluate", {
    expression: performanceExpression,
    awaitPromise: true,
    returnByValue: true,
  }, sessionId);
  const performanceActual = performanceEvaluated.result.result.value;
  results.push({
    name: "unrelated streaming mutations do not reconcile",
    pass: performanceActual.irrelevantStream.characterDataStream.observerCallbackCount === 0 &&
      performanceActual.irrelevantStream.characterDataStream.reconcileCount === 0 &&
      performanceActual.irrelevantStream.childListStream.observerCallbackCount === 0 &&
      performanceActual.irrelevantStream.childListStream.asideCallbackCount === 0 &&
      performanceActual.irrelevantStream.childListStream.relevantMutationBatchCount === 0 &&
      performanceActual.irrelevantStream.childListStream.reconcileCount === 0,
    expected: { characterDataObserverCallbacks: 0, childListObserverCallbacks: 0, relevantMutationBatchCount: 0, reconcileCount: 0 },
    actual: performanceActual.irrelevantStream,
  });
  results.push({
    name: "live sidebar aside mutations do not reconcile",
    pass: performanceActual.irrelevantStream.sidebarStream.observerCallbackCount === 0 &&
      performanceActual.irrelevantStream.sidebarStream.asideCallbackCount === 0 &&
      performanceActual.irrelevantStream.sidebarStream.relevantMutationBatchCount === 0 &&
      performanceActual.irrelevantStream.sidebarStream.reconcileCount === 0,
    expected: { sidebarObserverCallbacks: 0, sidebarRelevantBatches: 0, sidebarReconciles: 0 },
    actual: performanceActual.irrelevantStream.sidebarStream,
  });
  results.push({
    name: "new banner is discovered and relevant mutations are coalesced",
    pass: performanceActual.discovery.status.decision === "hidden" &&
      performanceActual.discovery.hidden === 1 &&
      performanceActual.relevantStream.observerCallbackCount > 0 &&
      performanceActual.relevantStream.relevantMutationBatchCount > 0 &&
      performanceActual.relevantStream.reconcileCount <= 2 &&
      performanceActual.relevantStream.status.decision === "hidden" &&
      performanceActual.relevantStream.hidden === 1,
    expected: { discoveredDecision: "hidden", maximumReconcileCount: 2, decision: "hidden", hidden: 1 },
    actual: { discovery: performanceActual.discovery, relevantStream: performanceActual.relevantStream },
  });
  output = { ok: results.every(result => result.pass), results };
} catch (error) {
  output = { ok: false, error: String(error) };
} finally {
  child.kill("SIGTERM");
  await new Promise(resolve => {
    const timer = setTimeout(resolve, 4000);
    child.once("exit", () => {
      clearTimeout(timer);
      resolve();
    });
  });
  try {
    await rm(profile, { recursive: true, force: true, maxRetries: 20, retryDelay: 250 });
  } catch (error) {
    console.error(`warning: could not remove disposable profile: ${error}`);
  }
}

console.log(JSON.stringify(output, null, 2));
if (!output.ok) process.exitCode = 1;
