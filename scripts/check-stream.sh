#!/bin/bash
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
build="$root/.local-build"
mkdir -p "$build/module-cache"
xcrun swiftc -swift-version 5 -module-cache-path "$build/module-cache" \
  "$root/boringNotch/XPCHelperClient/BoringNotchXPCHelperProtocol.swift" \
  "$root/boringNotch/extensions/PanGesture.swift" \
  "$root/Tests/NotchIntegration/SettingsWindowStub.swift" \
  "$root"/boringNotch/components/Codex/*.swift \
  "$root/Tests/NotchIntegration/NotchStreamChecks.swift" -o "$build/notch-stream-checks"
"$build/notch-stream-checks"

for check in CodexCompletionChecks CodexReconnectChecks CodexFrameChecks; do
  xcrun swiftc -swift-version 5 -module-cache-path "$build/module-cache" \
    "$root/boringNotch/XPCHelperClient/BoringNotchXPCHelperProtocol.swift" \
    "$root/boringNotch/extensions/PanGesture.swift" \
  "$root/Tests/NotchIntegration/SettingsWindowStub.swift" \
  "$root"/boringNotch/components/Codex/*.swift \
    "$root/Tests/NotchIntegration/$check.swift" -o "$build/$check"
  "$build/$check"
done
