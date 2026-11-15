#!/bin/bash
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
build="$root/.local-build"
mkdir -p "$build/module-cache"
xcrun swiftc -swift-version 5 -module-cache-path "$build/module-cache" \
  "$root/boringNotch/XPCHelperClient/BoringNotchXPCHelperProtocol.swift" \
  "$root/boringNotch/components/Codex/NotchResources.swift" \
  "$root/Tests/NotchIntegration/ResourceChecks.swift" -o "$build/resource-checks"
"$build/resource-checks"
xcrun swiftc -module-cache-path "$build/module-cache" \
  "$root/BoringNotchXPCHelper/CodexUsageReader.swift" \
  "$root/Tests/NotchIntegration/CodexUsageChecks.swift" -o "$build/usage-checks"
# Synthetic by default. --live is an explicit, read-only account quota query.
"$build/usage-checks" "${1:-}"
