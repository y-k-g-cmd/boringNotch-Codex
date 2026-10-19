#!/bin/bash
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
build="$root/.local-build"
mkdir -p "$build/module-cache"
sources=(
 "$root/Tests/NotchIntegration/ShelfHostStubs.swift"
 "$root/boringNotch/models/SharingStateManager.swift"
 "$root/boringNotch/helpers/AssociatedObject.swift"
 "$root/boringNotch/helpers/NotchHapticFeedback.swift"
 "$root/boringNotch/extensions/URL+SecurityScoped.swift"
 "$root/boringNotch/extensions/NSItemProvider+LoadHelpers.swift"
 "$root/boringNotch/extensions/NSMenu+AssociatedObject.swift"
 "$root/boringNotch/components/Shelf/Models/"*.swift
 "$root/boringNotch/components/Shelf/ViewModels/"*.swift
 "$root/boringNotch/components/Shelf/Views/ShelfView.swift"
 "$root/boringNotch/components/Shelf/Views/ShelfItemView.swift"
 "$root/boringNotch/components/Shelf/Views/DragPreviewView.swift"
)
for file in "$root/boringNotch/components/Shelf/Services/"*.swift; do
 case "$file" in *QuickShareService.swift|*ShareServiceFinder.swift) ;; *) sources+=("$file");; esac
done
xcrun swiftc -typecheck -swift-version 5 -module-cache-path "$build/module-cache" "${sources[@]}"

xcrun swiftc -swift-version 5 -module-cache-path "$build/module-cache" "${sources[@]}" \
  "$root/Tests/NotchIntegration/ShelfChecks.swift" -o "$build/shelf-checks"
"$build/shelf-checks"
