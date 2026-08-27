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
    const pass = actual.status.decision === test.decision &&
      actual.status.hiddenCount === test.hidden &&
      actual.marked === test.hidden &&
      actual.clicks === 0;
    results.push({ name: test.name, pass, expected: { decision: test.decision, hidden: test.hidden }, actual });
  }
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
  await rm(profile, { recursive: true, force: true });
}

console.log(JSON.stringify(output, null, 2));
if (!output.ok) process.exitCode = 1;
