(() => {
  "use strict";

  const VERSION = "1.1.1";
  const MARKER = "data-codex-limit-banner-hider";
  const STYLE_ID = "codex-limit-banner-hider-style";
  const STATUS_KEY = "__codexLimitBannerHiderStatus";
  const INSTANCE_KEY = "__codexLimitBannerHiderInstance";
  const TEST_MODE_KEY = "__CODEX_LIMIT_BANNER_HIDER_TEST_MODE__";

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
    return [...root.querySelectorAll("*")].some(element =>
      element.classList.contains("electron:h-toolbar"),
    );
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

  function scan() {
    if (!isMainWindow()) {
      setStatus({ decision: "identity-mismatch", exactTitleCount: 0, qualifiedCount: 0, hiddenCount: 0 });
      return;
    }

    ensureStyle();
    const root = document.querySelector("#root") || document.body;
    const asides = [...root.querySelectorAll("aside")];
    const exactTitleCount = asides.filter(aside => titleMatches(aside) !== null).length;
    const qualified = asides.filter(matchesBlockingBanner);

    for (const marked of root.querySelectorAll(`aside[${MARKER}]`)) {
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
      hiddenCount: root.querySelectorAll(`aside[${MARKER}="hidden"]`).length,
    });
  }

  const existing = globalThis[INSTANCE_KEY];
  if (existing?.version === VERSION && typeof existing.scan === "function") {
    existing.scan();
    return;
  }

  let scheduled = false;
  const scheduleScan = () => {
    if (scheduled) return;
    scheduled = true;
    queueMicrotask(() => {
      scheduled = false;
      scan();
    });
  };

  const start = () => {
    if (!isMainWindow()) {
      setStatus({ decision: "identity-mismatch", exactTitleCount: 0, qualifiedCount: 0, hiddenCount: 0 });
      return;
    }
    const observer = new MutationObserver(scheduleScan);
    observer.observe(document.documentElement, { childList: true, subtree: true, characterData: true });
    globalThis[INSTANCE_KEY].observer = observer;
    scan();
  };

  globalThis[INSTANCE_KEY] = { version: VERSION, scan, matchesBlockingBanner, observer: null };
  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", start, { once: true });
  } else {
    start();
  }
})();
