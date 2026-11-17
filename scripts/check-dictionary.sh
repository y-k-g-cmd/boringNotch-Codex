#!/bin/bash
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
build="$root/.local-build/dictionary-check"
mkdir -p "$build"
python3 - "$root" "$build" <<'INNER'
from pathlib import Path
import sys
root, build = map(Path, sys.argv[1:])
s=(root/'boringNotch/Shortcuts/ShortcutConstants.swift').read_text()
a=s.index('struct NotchDictionaryEntry:'); b=s.index('@MainActor\nfinal class NotchDictionary',a)
(build/'main.swift').write_text('import Foundation\n'+s[a:b]+(root/'Tests/NotchIntegration/DictionaryChecks.swift').read_text())
INNER
xcrun swift -module-cache-path "$root/.local-build/module-cache" "$build/main.swift"
