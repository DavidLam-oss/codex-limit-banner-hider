(() => {
  "use strict";

  const VERSION = "1.2.2";
  const MARKER = "data-codex-limit-banner-hider";
  const STYLE_ID = "codex-limit-banner-hider-style";
  const STATUS_KEY = "__codexLimitBannerHiderStatus";
  const INSTANCE_KEY = "__codexLimitBannerHiderInstance";
  const TEST_MODE_KEY = "__CODEX_LIMIT_BANNER_HIDER_TEST_MODE__";
  const RECONCILE_DELAY_MS = 200;
  const DISCOVERY_INTERVAL_MS = 1_000;
  const STARTUP_RETRY_MS = 250;
  const STARTUP_TIMEOUT_MS = 10_000;

  const BLOCKING_TITLES = new Set([
    "You’re out of Codex and Work usage",
    "You've used all Codex and Work usage",
    "You’ve used all Codex and Work usage",
  ]);

  const ALLOWED_ACTIONS = new Set([
    "Upgrade",
    "Upgrade to Pro",
    "Reset usage",
    "Add Credits",
    "Buy credits",
    "Try Plus",
    "View Usage",
    "Notify owner",
    "Contact owner",
    "Request Increase",
    "Increase Usage Limit",
    "Invite",
    "Refer",
  ]);

  const BLOCKING_MESSAGES = [
    /^Contact your admin to increase your usage limit$/iu,
    /^Increase your usage limit$/iu,
    /^Your workspace is out of credits\. Ask your workspace owner to add more$/iu,
    /^Your workspace is out of credits\. Add credits to continue using Codex and Work$/iu,
    /^Add credits or upgrade your plan(?: — or wait for usage to reset on .+)?$/iu,
    /^Add credits to keep going now(?:, or wait for usage to reset on .+)?$/iu,
    /^Try Plus for more now(?:, or wait for usage to reset on .+)?$/iu,
    /^Upgrade for more now(?:, or wait for usage to reset on .+)?$/iu,
    /^Contact your admin for more access(?:, or wait for usage to reset on .+)?$/iu,
    /^You’ve reached your usage limit$/iu,
    /^Your usage resets on .+$/iu,
    /^Your rate limit resets? on .+$/iu,
  ];

  const normalize = value => String(value ?? "").replace(/\s+/gu, " " ).trim();
  const ownText = element => normalize(
    [...element.childNodes]
      .filter(node => node.nodeType === Node.TEXT_NODE)
      .map(node => node.textContent)
      .join(" "),
  );

  function isMainWindow() {
    if (globalThis[TEST_MODE_KEY] === true) return true;
    if (location.href !== "app://-/index.html" || document.title !== "ChatGPT") return false;
    const root = document.querySelector("#root");
    if (!root) return false;
    return root.querySelector('[class~="electron:h-toolbar"]') !== null;
  }

  function titleMatches(aside) {
    const matches = [...aside.querySelectorAll("h3, h3 *")].filter(element =>
      BLOCKING_TITLES.has(ownText(element)),
    );
    if (matches.length !== 1) return null;
    const title = ownText(matches[0]);
    const heading = matches[0].closest("h3");
    if (!heading || heading.closest("aside") !== aside) return null;
    if (aside.querySelectorAll("h3").length !== 1) return null;
    return { heading, title };
  }

  function matchesBlockingBanner(aside) {
    if (!(aside instanceof HTMLElement) || aside.tagName !== "ASIDE") return false;
    if (aside.querySelector("aside")) return false;
    if (!aside.classList.contains("w-full") ||
        !aside.classList.contains("rounded-2xl") ||
        !aside.classList.contains("bg-surface")) return false;

    const titleMatch = titleMatches(aside);
    if (!titleMatch) return false;

    const message = normalize(normalize(titleMatch.heading.textContent).replace(titleMatch.title, ""));
    if (!BLOCKING_MESSAGES.some(pattern => pattern.test(message))) return false;

    const buttons = [...aside.querySelectorAll("button")].map(button => normalize(button.textContent));
    if (buttons.length < 1 || buttons.length > 3) return false;
    if (buttons.some(label => !ALLOWED_ACTIONS.has(label))) return false;
    if (!aside.querySelector("svg")) return false;
    return true;
  }

  function ensureStyle() {
    if (document.getElementById(STYLE_ID)) return;
    const style = document.createElement("style");
    style.id = STYLE_ID;
    style.textContent = `aside[${MARKER}="hidden"] { display: none !important; }`;
    (document.head || document.documentElement).append(style);
  }

  function setStatus(fields) {
    globalThis[STATUS_KEY] = {
      version: VERSION,
      updatedAt: new Date().toISOString(),
      ...fields,
    };
  }

  const knownAsides = new Set();
  // Asides currently passing the structural prefilter (the banner class
  // triple). Only these carry a MutationObserver, so text and node churn in
  // unrelated live asides (sidebars, composers) never enters the callback.
  const shapedAsides = new Set();
  const metrics = {
    fullScanCount: 0,
    discoveryPollCount: 0,
    reconcileCount: 0,
    observerCallbackCount: 0,
    asideCallbackCount: 0,
    relevantMutationBatchCount: 0,
  };
  let asideObserver = null;
  let discoveryTimer = null;
  let reconcileTimer = null;
  let startupTimer = null;

  function isBannerShaped(aside) {
    return aside.classList.contains("w-full") &&
        aside.classList.contains("rounded-2xl") &&
        aside.classList.contains("bg-surface");
  }

  const OBSERVE_OPTIONS = {
    childList: true,
    subtree: true,
    characterData: true,
    attributes: true,
    attributeFilter: ["class"],
  };

  // Brings the observation state of one aside in line with its shape.
  // Returns true when the observation state changed.
  function syncObservation(aside) {
    if (asideObserver === null) return false;
    const shaped = isBannerShaped(aside);
    const wasShaped = shapedAsides.has(aside);
    if (shaped === wasShaped) return false;
    if (shaped) {
      shapedAsides.add(aside);
      asideObserver.observe(aside, OBSERVE_OPTIONS);
      return true;
    }
    // MutationObserver cannot unobserve a single node; rebuild instead.
    shapedAsides.delete(aside);
    asideObserver.disconnect();
    for (const remaining of shapedAsides) {
      asideObserver.observe(remaining, OBSERVE_OPTIONS);
    }
    return true;
  }

  function trackAside(aside) {
    if (aside instanceof HTMLElement && aside.tagName === "ASIDE" && aside.isConnected) {
      knownAsides.add(aside);
      syncObservation(aside);
      return true;
    }
    return false;
  }

  function trackClosestAside(node) {
    const element = node instanceof Element ? node : node?.parentElement;
    if (!element) return false;
    const aside = element.matches("aside") ? element : element.closest("aside");
    if (!aside) return false;
    trackAside(aside);
    return true;
  }

  function trackContainedAsides(node) {
    if (!(node instanceof Element)) return false;
    let found = false;
    if (node.matches("aside")) {
      found = true;
      trackAside(node);
    }
    const firstNestedAside = node.querySelector("aside");
    if (!firstNestedAside) return found;
    found = true;
    trackAside(firstNestedAside);
    for (const aside of node.querySelectorAll("aside")) trackAside(aside);
    return found;
  }

  function updateTrackedAsides(record) {
    let relevant = trackClosestAside(record.target);
    if (record.type !== "childList") return relevant;
    for (const node of record.addedNodes) {
      if (trackContainedAsides(node)) relevant = true;
    }
    for (const node of record.removedNodes) {
      if (node instanceof Element && (node.matches("aside") || node.querySelector("aside"))) relevant = true;
    }
    return relevant;
  }

  function reconcile() {
    metrics.reconcileCount += 1;
    for (const aside of knownAsides) {
      if (!aside.isConnected) {
        knownAsides.delete(aside);
        shapedAsides.delete(aside);
      }
    }
    const asides = [...knownAsides];
    const exactTitleCount = asides.filter(aside => titleMatches(aside) !== null).length;
    const qualified = asides.filter(matchesBlockingBanner);

    for (const marked of asides.filter(aside => aside.hasAttribute(MARKER))) {
      if (qualified.length !== 1 || marked !== qualified[0]) marked.removeAttribute(MARKER);
    }

    let decision = "absent";
    if (qualified.length === 1) {
      qualified[0].setAttribute(MARKER, "hidden");
      decision = "hidden";
    } else if (qualified.length > 1) {
      decision = "ambiguous";
    } else if (exactTitleCount > 0) {
      decision = "structure-rejected";
    }

    setStatus({
      decision,
      exactTitleCount,
      qualifiedCount: qualified.length,
      hiddenCount: asides.filter(aside => aside.getAttribute(MARKER) === "hidden").length,
    });
  }

  function scan() {
    metrics.fullScanCount += 1;
    const root = document.querySelector("#root") || document.body;
    if (!root) {
      setStatus({ decision: "identity-waiting", exactTitleCount: 0, qualifiedCount: 0, hiddenCount: 0 });
      return;
    }
    for (const aside of root.querySelectorAll("aside")) trackAside(aside);
    reconcile();
  }

  function discoverNewAsides() {
    metrics.discoveryPollCount += 1;
    const root = document.querySelector("#root") || document.body;
    if (!root) return false;

    let changed = false;
    for (const aside of knownAsides) {
      if (!aside.isConnected) {
        knownAsides.delete(aside);
        shapedAsides.delete(aside);
        changed = true;
      }
    }
    for (const aside of root.querySelectorAll("aside")) {
      const wasShaped = shapedAsides.has(aside);
      const isNew = !knownAsides.has(aside);
      trackAside(aside);
      if (isNew || shapedAsides.has(aside) !== wasShaped) changed = true;
    }
    return changed;
  }

  function scheduleDiscovery() {
    if (discoveryTimer !== null) return;
    discoveryTimer = setTimeout(() => {
      discoveryTimer = null;
      // A hidden window cannot show a banner; skip the query entirely.
      if (!document.hidden) {
        if (discoverNewAsides()) reconcile();
      }
      scheduleDiscovery();
    }, DISCOVERY_INTERVAL_MS);
  }

  function scheduleReconcile() {
    if (reconcileTimer !== null) return;
    reconcileTimer = setTimeout(() => {
      reconcileTimer = null;
      reconcile();
    }, RECONCILE_DELAY_MS);
  }

  function handleAsideMutations(records) {
    metrics.observerCallbackCount += 1;
    metrics.asideCallbackCount += 1;
    let relevant = false;
    for (const record of records) {
      if (updateTrackedAsides(record)) relevant = true;
    }
    if (!relevant) return;
    metrics.relevantMutationBatchCount += 1;
    scheduleReconcile();
  }

  function destroy() {
    asideObserver?.disconnect();
    shapedAsides.clear();
    if (discoveryTimer !== null) clearTimeout(discoveryTimer);
    if (reconcileTimer !== null) clearTimeout(reconcileTimer);
    if (startupTimer !== null) clearTimeout(startupTimer);
    discoveryTimer = null;
    reconcileTimer = null;
    startupTimer = null;
  }

  const existing = globalThis[INSTANCE_KEY];
  if (existing?.version === VERSION && typeof existing.scan === "function") {
    existing.scan();
    return;
  }
  if (typeof existing?.destroy === "function") {
    existing.destroy();
  } else {
    existing?.observer?.disconnect();
  }

  const instance = { version: VERSION, scan, matchesBlockingBanner, observer: null, asideObserver: null, metrics, destroy };
  globalThis[INSTANCE_KEY] = instance;
  const startupDeadline = Date.now() + STARTUP_TIMEOUT_MS;

  const start = () => {
    if (!isMainWindow()) {
      setStatus({ decision: "identity-waiting", exactTitleCount: 0, qualifiedCount: 0, hiddenCount: 0 });
      if (Date.now() < startupDeadline) startupTimer = setTimeout(start, STARTUP_RETRY_MS);
      return;
    }
    startupTimer = null;
    ensureStyle();
    asideObserver = new MutationObserver(handleAsideMutations);
    instance.observer = asideObserver;
    instance.asideObserver = asideObserver;
    scan();
    scheduleDiscovery();
  };

  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", start, { once: true });
  } else {
    start();
  }
})();
