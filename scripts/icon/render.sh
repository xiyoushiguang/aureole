#!/bin/bash
# Renders the app icon candidates into design/icon-candidates/. Usage: scripts/icon/render.sh
set -euo pipefail
cd "$(dirname "$0")/../.."
swift scripts/icon/render-icons.swift design/icon-candidates
