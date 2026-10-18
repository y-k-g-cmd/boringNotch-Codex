#!/bin/bash
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
if ! xcrun --find xcodebuild >/dev/null 2>&1 || ! xcodebuild -version >/dev/null 2>&1; then
  if [[ -d /Applications/Xcode.app/Contents/Developer ]]; then
    export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
  else
    echo "Xcode is not ready. Install and open Xcode to finish first-run setup." >&2
    exit 1
  fi
fi
mkdir -p "$root/.local-build/ModuleCache"
export CLANG_MODULE_CACHE_PATH="$root/.local-build/ModuleCache"
export SWIFT_MODULECACHE_PATH="$root/.local-build/ModuleCache"
export SWIFTPM_MODULECACHE_OVERRIDE="$root/.local-build/ModuleCache"
xcodebuild -project "$root/boringNotch.xcodeproj" -scheme boringNotch \
  -configuration Debug -derivedDataPath "$root/.local-build/Xcode" \
  -clonedSourcePackagesDirPath "$root/.local-build/SourcePackages" \
  MODULE_CACHE_DIR="$root/.local-build/ModuleCache" \
  CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM= build
printf '\nBuilt app: %s\n' "$root/.local-build/Xcode/Build/Products/Debug/boringNotch.app"
