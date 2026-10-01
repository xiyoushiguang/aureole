#!/bin/bash
# Send a debug command to the running app: scripts/dev-cmd.sh open|close|expand|refresh|hooks-install|hooks-remove
set -euo pipefail
case "${1:-}" in open|close|expand|refresh|hooks-install|hooks-remove) ;; *) echo "usage: $0 open|close|expand|refresh|hooks-install|hooks-remove"; exit 2;; esac
cat > "${TMPDIR:-/tmp}/aureole-cmd.swift" <<SWIFT
import Foundation
DistributedNotificationCenter.default().postNotificationName(Notification.Name("app.aureole.$1"), object: nil, userInfo: nil, deliverImmediately: true)
SWIFT
swift "${TMPDIR:-/tmp}/aureole-cmd.swift"
