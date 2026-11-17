#!/bin/bash
set -euo pipefail
# Wrap the already verified beta ZIP in a read-only drag-to-install disk image.
[[ $# == 2 ]] || { echo 'Usage: package-dmg.sh <assets-directory> <release-tag>' >&2; exit 2; }
out="$(cd "$1" && pwd)"
release="$2"
[[ "$release" =~ ^v[0-9]+\.[0-9]+\.[0-9]+-beta\.[0-9]+$ ]] || exit 2
name="boringNotch-Codex-$release"
[[ ! -e "$out/$name-universal.dmg" ]] || { echo 'DMG already exists' >&2; exit 2; }
scratch="$(mktemp -d /private/tmp/notch-dmg.XXXXXX)"
mounted=false
cleanup() { if $mounted; then hdiutil detach "$scratch/mount" >/dev/null; fi; rm -rf "$scratch"; }
trap cleanup EXIT
ditto -x -k "$out/$name-universal.zip" "$scratch/unpacked"
stage="$scratch/unpacked/boringNotch-Codex-beta"
ln -s /Applications "$stage/Applications"
codesign --verify --deep --strict "$stage/boringNotch Codex.app"
hdiutil create -volname "boringNotch Codex $release" -srcfolder "$stage" -format UDZO "$out/$name-universal.dmg"
hdiutil verify "$out/$name-universal.dmg"
mkdir "$scratch/mount"
hdiutil attach "$out/$name-universal.dmg" -readonly -nobrowse -mountpoint "$scratch/mount"
mounted=true
codesign --verify --deep --strict "$scratch/mount/boringNotch Codex.app"
cmp "$scratch/mount/BUILD-INFO.json" "$out/BUILD-INFO.json"
[[ "$(readlink "$scratch/mount/Applications")" == /Applications ]]
hdiutil detach "$scratch/mount"
mounted=false
(cd "$out" && shasum -a 256 "$name-universal.dmg" "$name-universal.zip" "$name-source.tar.gz" BUILD-INFO.json INSTALL.md > SHA256SUMS.txt)
echo "PASS: DMG verified, mounted read-only, app signature intact, metadata and installation link checked"
