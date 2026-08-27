#!/bin/zsh
set -euo pipefail

readonly ROOT_DIR="${0:A:h:h}"
readonly TEST_TMP="$(mktemp -d "${TMPDIR:-/tmp}/codex-limit-banner-hider-tests.XXXXXX")"
trap '/bin/rm -rf -- "${TEST_TMP:?}"' EXIT

print "Checking shell and JavaScript syntax..."
/bin/zsh -n "$ROOT_DIR/install.sh" "$ROOT_DIR/status.sh" "$ROOT_DIR/uninstall.sh"
/usr/bin/env node --check "$ROOT_DIR/src/injected.js"
/usr/bin/env node --check "$ROOT_DIR/test/injection-cdp-test.mjs"

print "Compiling Swift controller..."
/usr/bin/swiftc -O -o "$TEST_TMP/codex-limit-banner-hider-controller" "$ROOT_DIR/src/controller.swift"
"$TEST_TMP/codex-limit-banner-hider-controller" self-test-processes >/dev/null

if [[ -x /Applications/ChatGPT.app/Contents/MacOS/ChatGPT ]]; then
  print "Running isolated private-pipe controller test..."
  "$TEST_TMP/codex-limit-banner-hider-controller" self-test-pipe "$ROOT_DIR/src/injected.js" >"$TEST_TMP/pipe-test.json"
  /usr/bin/grep -q '"mode" : "managed"' "$TEST_TMP/pipe-test.json"
  /usr/bin/grep -Eq '"decision" : "(absent|hidden)"' "$TEST_TMP/pipe-test.json"

  print "Running ten isolated DOM matching cases..."
  /usr/bin/env node "$ROOT_DIR/test/injection-cdp-test.mjs"
else
  print "Codex is not installed; skipping local CDP integration tests."
fi

print "All available tests passed."
