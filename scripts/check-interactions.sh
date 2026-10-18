#!/bin/bash
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
build="$root/.local-build"
mkdir -p "$build/module-cache"
xcrun swiftc -swift-version 5 -module-cache-path "$build/module-cache" \
  "$root/boringNotch/components/Codex/CodexState.swift" \
  "$root/boringNotch/components/Codex/CodexIPCTransport.swift" \
  "$root/boringNotch/extensions/PanGesture.swift" \
  "$root/Tests/NotchIntegration/CodexInteractionChecks.swift" -o "$build/codex-interaction-checks"
"$build/codex-interaction-checks"
