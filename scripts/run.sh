#!/bin/bash
# Build (debug) and launch Aureole.app, replacing any running instance.
set -euo pipefail
cd "$(dirname "$0")/.."
scripts/build-app.sh debug
pkill -x Aureole 2>/dev/null || true
sleep 0.5
# --dev: listen for scripts/dev-cmd.sh. An app opened the usual way does not.
open build/Aureole.app --args --dev
echo "Launched. Log: ~/Library/Logs/Aureole/aureole.log"
