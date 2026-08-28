#!/bin/zsh
set -euo pipefail

readonly PRODUCT_NAME="Codex Limit Banner Hider"
readonly SUPPORT_DIR="$HOME/Library/Application Support/$PRODUCT_NAME"
readonly INSTALL_DIR="$SUPPORT_DIR/install"
readonly BIN_DIR="$INSTALL_DIR/bin"
readonly SHARE_DIR="$INSTALL_DIR/share"
readonly STATE_DIR="$SUPPORT_DIR/state"
readonly LABEL="com.codex-limit-banner-hider.controller"
readonly LAUNCH_AGENT="$HOME/Library/LaunchAgents/$LABEL.plist"
readonly APP_PATH="/Applications/ChatGPT.app"
readonly APP_EXECUTABLE="$APP_PATH/Contents/MacOS/ChatGPT"
readonly SOURCE_DIR="${0:A:h}"
readonly CONTROLLER_SOURCE="$SOURCE_DIR/src/controller.swift"
readonly INJECTION_SOURCE="$SOURCE_DIR/src/injected.js"
readonly REQUIREMENT='identifier "com.openai.codex" and anchor apple generic and certificate leaf[subject.OU] = "2DC432GLL2"'

if [[ ! -x "$APP_EXECUTABLE" ]]; then
  print -u2 "Codex was not found at $APP_PATH"
  exit 1
fi

/usr/bin/codesign --verify --deep --strict -R="$REQUIREMENT" "$APP_PATH"
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP_PATH/Contents/Info.plist")" == "com.openai.codex" ]]
[[ -f "$CONTROLLER_SOURCE" && -f "$INJECTION_SOURCE" ]]

/bin/mkdir -p "$BIN_DIR" "$SHARE_DIR" "$STATE_DIR" "${LAUNCH_AGENT:h}"
/usr/bin/swiftc -O -o "$BIN_DIR/codex-limit-banner-hider-controller.new" "$CONTROLLER_SOURCE"
/bin/chmod 700 "$BIN_DIR/codex-limit-banner-hider-controller.new"
/bin/mv -f "$BIN_DIR/codex-limit-banner-hider-controller.new" "$BIN_DIR/codex-limit-banner-hider-controller"
/usr/bin/install -m 600 "$INJECTION_SOURCE" "$SHARE_DIR/injected.js"

current_pid="$(/bin/ps -axo pid=,command= | /usr/bin/awk -v exe="$APP_EXECUTABLE" '{ line=$0; sub(/^[[:space:]]+/, "", line); pid=line; sub(/[[:space:]].*$/, "", pid); command=line; sub(/^[^[:space:]]+[[:space:]]+/, "", command); if (!found && (command == exe || index(command, exe " ") == 1)) { print pid; found=1 } }')"

/bin/chmod 700 "$STATE_DIR"
/usr/bin/python3 - "$STATE_DIR/runtime.json" "$current_pid" <<'PY'
import json, os, sys, tempfile
path, pid = sys.argv[1], sys.argv[2]
state = {}
try:
    with open(path, encoding="utf-8") as handle:
        state = json.load(handle)
except (FileNotFoundError, json.JSONDecodeError):
    pass
state.pop("managedPID", None)
state.pop("managedStartedAt", None)
state.pop("managedProcessStartedAt", None)
state.pop("skipStartedAt", None)
state.pop("skipSignatureValid", None)
state.pop("skipLastError", None)
if pid:
    state["skipPID"] = int(pid)
    state["skipDecision"] = "current-process-preserved"
    state["skipSignatureValid"] = True
else:
    state.pop("skipPID", None)
    state.pop("skipDecision", None)
directory = os.path.dirname(path)
fd, temporary = tempfile.mkstemp(dir=directory, prefix="runtime.", suffix=".tmp")
try:
    with os.fdopen(fd, "w", encoding="utf-8") as handle:
        json.dump(state, handle, indent=2, sort_keys=True)
        handle.write("\n")
    os.chmod(temporary, 0o600)
    os.replace(temporary, path)
finally:
    if os.path.exists(temporary):
        os.unlink(temporary)
PY

escaped_controller="$BIN_DIR/codex-limit-banner-hider-controller"
escaped_stdout="$STATE_DIR/controller.log"
escaped_stderr="$STATE_DIR/controller-error.log"
/usr/bin/python3 - "$LAUNCH_AGENT" "$LABEL" "$escaped_controller" "$escaped_stdout" "$escaped_stderr" <<'PY'
import plistlib, sys
path, label, controller, stdout, stderr = sys.argv[1:]
payload = {
    "Label": label,
    "ProgramArguments": [controller, "supervise"],
    "RunAtLoad": True,
    "KeepAlive": True,
    "ProcessType": "Background",
    "StandardOutPath": stdout,
    "StandardErrorPath": stderr,
}
with open(path, "wb") as handle:
    plistlib.dump(payload, handle, sort_keys=True)
PY
/bin/chmod 600 "$LAUNCH_AGENT"

/bin/launchctl bootout "gui/$UID/$LABEL" >/dev/null 2>&1 || true
for _ in {1..50}; do
    if ! /bin/launchctl print "gui/$UID/$LABEL" >/dev/null 2>&1; then
        break
    fi
    /bin/sleep 0.1
done

bootstrapped=false
for _ in {1..25}; do
    if /bin/launchctl bootstrap "gui/$UID" "$LAUNCH_AGENT" >/dev/null 2>&1; then
        bootstrapped=true
        break
    fi
    /bin/sleep 0.2
done
if [[ "$bootstrapped" != true ]]; then
    print -u2 "Could not load $LABEL after waiting for the previous controller to exit."
    /bin/launchctl bootstrap "gui/$UID" "$LAUNCH_AGENT"
fi
/bin/launchctl enable "gui/$UID/$LABEL"
/bin/launchctl kickstart -k "gui/$UID/$LABEL"

/bin/sleep 2
"$BIN_DIR/codex-limit-banner-hider-controller" status
if [[ -n "$current_pid" ]]; then
  print "Current Codex PID $current_pid was preserved. Hiding starts after the next normal Codex launch."
else
  print "Installed. Hiding starts with the next normal Codex launch."
fi
