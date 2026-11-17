#!/bin/bash
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
output="$(mktemp -d /private/tmp/notch-quota-check.XXXXXX)"
trap 'rm -rf "$output"' EXIT
python3 - "$root" "$output" <<'PYTHON'
from pathlib import Path
import sys
root=Path(sys.argv[1]);s=(root/'boringNotch/components/Codex/NotchResources.swift').read_text()
policy=s[s.index('struct QuotaFailurePolicy'):s.index('struct NotchCPUSample')]
(Path(sys.argv[2])/'main.swift').write_text(policy+(root/'Tests/NotchIntegration/QuotaFailureChecks.swift').read_text())
PYTHON
xcrun swift -module-cache-path /private/tmp/notch-quota-module-cache "$output/main.swift"
