#!/bin/zsh
set -euo pipefail

readonly CONTROLLER="$HOME/Library/Application Support/Codex Limit Banner Hider/install/bin/codex-limit-banner-hider-controller"
if [[ ! -x "$CONTROLLER" ]]; then
  print "Codex Limit Banner Hider is not installed."
  exit 1
fi
exec "$CONTROLLER" status "$@"
