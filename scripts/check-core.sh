#!/bin/bash
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
# Both targets compile their own copy of the Objective-C XPC contract.
cmp "$root/boringNotch/XPCHelperClient/BoringNotchXPCHelperProtocol.swift" \
  "$root/BoringNotchXPCHelper/BoringNotchXPCHelperProtocol.swift"
build="$root/.local-build"
mkdir -p "$build/module-cache"
xcrun swiftc -swift-version 5 -module-cache-path "$build/module-cache" \
  "$root/boringNotch/components/Codex/CodexState.swift" \
  "$root/boringNotch/components/Shelf/Models/ShelfZone.swift" \
  "$root/Tests/NotchIntegration/CoreChecks.swift" -o "$build/core-checks"
"$build/core-checks"
xcrun swiftc -typecheck -swift-version 5 -module-cache-path "$build/module-cache" \
  "$root/boringNotch/XPCHelperClient/BoringNotchXPCHelperProtocol.swift" \
  "$root/boringNotch/extensions/PanGesture.swift" \
  "$root"/boringNotch/components/Codex/*.swift
plutil -lint "$root/boringNotch.xcodeproj/project.pbxproj"
