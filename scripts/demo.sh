#!/bin/bash
# Build (debug) and open Aureole with sample data: no agent, sign-in or hook needed. Quit a running Aureole first
# if you want only one notch panel. Settings changed in the demo go to a scratch domain and are thrown away.
set -euo pipefail
cd "$(dirname "$0")/.."
scripts/build-app.sh debug
open -n build/Aureole.app --args --demo
