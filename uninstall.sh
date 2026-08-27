#!/bin/zsh
set -euo pipefail

readonly PRODUCT_NAME="Codex Limit Banner Hider"
readonly SUPPORT_DIR="$HOME/Library/Application Support/$PRODUCT_NAME"
readonly LABEL="com.codex-limit-banner-hider.controller"
readonly LAUNCH_AGENT="$HOME/Library/LaunchAgents/$LABEL.plist"
readonly STAMP="$(date +%Y%m%d-%H%M%S)"

/bin/launchctl bootout "gui/$UID/$LABEL" >/dev/null 2>&1 || true
if [[ -f "$LAUNCH_AGENT" ]]; then
  /bin/mv "$LAUNCH_AGENT" "$HOME/.Trash/$LABEL.plist.$STAMP"
fi
if [[ -d "$SUPPORT_DIR" ]]; then
  /bin/mv "$SUPPORT_DIR" "$HOME/.Trash/$PRODUCT_NAME.$STAMP"
fi
print "Uninstalled. Files were moved to Trash and can be recovered."
print "A currently running managed Codex remains unchanged until you quit it normally; the customization will not return on its next launch."
