#!/bin/bash
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
build="$root/.local-build/update-check"
mkdir -p "$build"
cat > "$build/main.swift" <<'SWIFT'
import Foundation
var info: [String: Any] = ["ForkRepositoryURL": "https://github.com/y-k-g-cmd/boringNotch-Codex"]
precondition(!ForkUpdateConfiguration.isEnabled(info: info))
info["ForkUpdatesEnabled"] = true
precondition(!ForkUpdateConfiguration.isEnabled(info: info))
info["SUFeedURL"] = "https://y-k-g-cmd.github.io/boringNotch-Codex/appcast.xml"
precondition(!ForkUpdateConfiguration.isEnabled(info: info))
info["SUPublicEDKey"] = Data(repeating: 1, count: 32).base64EncodedString()
precondition(ForkUpdateConfiguration.isEnabled(info: info))
info["SUFeedURL"] = "https://TheBoredTeam.github.io/boring.notch/appcast.xml"
precondition(!ForkUpdateConfiguration.isEnabled(info: info))
info["SUFeedURL"] = "http://y-k-g-cmd.github.io/boringNotch-Codex/appcast.xml"
precondition(!ForkUpdateConfiguration.isEnabled(info: info))
info["SUFeedURL"] = "https://github.com/y-k-g-cmd/boringNotch-Codex"
precondition(!ForkUpdateConfiguration.isEnabled(info: info))
info["SUFeedURL"] = "https://y-k-g-cmd.github.io/boringNotch-Codex/appcast.xml"
info["SUPublicEDKey"] = "invalid"
precondition(!ForkUpdateConfiguration.isEnabled(info: info))
info["SUPublicEDKey"] = Data(repeating: 1, count: 32).base64EncodedString()
info["ForkRepositoryURL"] = "https://github.com/TheBoredTeam/boring.notch/"
info["SUFeedURL"] = "https://theboredteam.github.io/boring.notch/appcast.xml"
precondition(!ForkUpdateConfiguration.isEnabled(info: info))
info["ForkRepositoryURL"] = "https://github.com/y-k-g-cmd/boringNotch-Codex"
info["SUFeedURL"] = "https://user@Y-K-G-CMD.github.io/boringNotch-Codex/appcast.xml"
precondition(!ForkUpdateConfiguration.isEnabled(info: info))
info["SUFeedURL"] = "https://y-k-g-cmd.github.io/boringNotch-Codex/appcast.xml"
info["ForkUpdatesEnabled"] = false
precondition(!ForkUpdateConfiguration.isEnabled(info: info))
print("PASS: update gate rejects disabled, missing, malformed, upstream, insecure and repository-page configurations; accepts an explicitly enabled own feed with correctly sized public key")
SWIFT
xcrun swiftc -module-cache-path "$build/module-cache" "$root/boringNotch/strings/constants.swift" "$build/main.swift" -o "$build/check-updates"
"$build/check-updates"
