#!/bin/bash
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
output="$(mktemp -d /private/tmp/notch-books-tests.XXXXXX)"
trap 'rm -rf "$output"' EXIT
xcrun swiftc -module-cache-path /private/tmp/notch-books-module-cache "$root/BoringNotchXPCHelper/RemoteBooksServer.swift" "$root/Tests/RemoteBooks/main.swift" -o "$output/check"
python3 "$root/Tests/RemoteBooks/check.py" "$output/check"
