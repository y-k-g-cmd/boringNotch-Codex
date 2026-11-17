#!/bin/bash
set -euo pipefail
if [[ $# -lt 3 || $# -gt 4 ]]; then
  echo 'Usage: package-beta.sh <archived.app> <new-output-directory> <source-commit> [release-tag]' >&2
  exit 2
fi
root="$(cd "$(dirname "$0")/.." && pwd)"
if [[ -z "${DEVELOPER_DIR:-}" && -d /Applications/Xcode.app/Contents/Developer ]]; then
  export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi
release="${4:-v0.1.0-beta.1}"
[[ "$release" =~ ^v[0-9]+\.[0-9]+\.[0-9]+-beta\.[0-9]+$ ]] || { echo 'Invalid beta tag.' >&2; exit 2; }
app="$1"
out="$2"
revision="$(git -C "$root" rev-parse --verify "$3^{commit}")"
[[ ! -e "$out" ]] || { echo 'Output directory must not already exist.' >&2; exit 2; }
[[ -d "$app/Contents" ]] || { echo 'Missing app bundle.' >&2; exit 2; }
codesign --verify --deep --strict "$app"
python3 - "$app" "$root" "$revision" "$release" <<'PY'
from pathlib import Path
import plistlib,subprocess,sys,re
p=Path(sys.argv[1]);d=plistlib.loads((p/'Contents/Info.plist').read_bytes())
assert d['CFBundleIdentifier']=='io.github.y-k-g-cmd.boringnotchcodex'
project=subprocess.check_output(['git','-C',sys.argv[2],'show',sys.argv[3]+':boringNotch.xcodeproj/project.pbxproj'],text=True)
expected=re.findall(r'CURRENT_PROJECT_VERSION = ([^;]+);',project)[-1]
assert d['CFBundleVersion']==expected
assert sys.argv[4].startswith('v'+d['CFBundleShortVersionString']+'-beta.')
assert tuple(map(int,d['LSMinimumSystemVersion'].split('.'))) >= (15,0)
assert not d.get('ForkUpdatesEnabled') and 'SUFeedURL' not in d and 'SUPublicEDKey' not in d
archs=subprocess.check_output(['lipo','-archs',str(p/'Contents/MacOS'/d['CFBundleExecutable'])],text=True).split()
assert set(archs)=={'arm64','x86_64'},archs
helper=p/'Contents/XPCServices/BoringNotchXPCHelper.xpc/Contents/Info.plist'
h=plistlib.loads(helper.read_bytes())
assert h['CFBundleIdentifier']==d['CFBundleIdentifier']+'.BoringNotchXPCHelper'
assert tuple(map(int,h.get('LSMinimumSystemVersion','15.0').split('.'))) <= tuple(map(int,d['LSMinimumSystemVersion'].split('.')))
helper_binary=helper.parent/'MacOS'/h['CFBundleExecutable']
assert set(subprocess.check_output(['lipo','-archs',str(helper_binary)],text=True).split())=={'arm64','x86_64'}
print('PASS: public identity, version, macOS 15 minimum, disabled updater and universal app')
PY
mkdir -p "$out"
# Keep live app bundles outside cloud-synced output folders: Finder may attach
# FinderInfo metadata there after copying, invalidating strict signature checks.
scratch="$(mktemp -d "${TMPDIR:-/tmp}/boringnotch-beta.XXXXXX")"
trap 'rm -rf "$scratch"' EXIT
stage="$scratch/boringNotch-Codex-beta"
mkdir "$stage"
ditto --norsrc --noextattr "$app" "$stage/boringNotch Codex.app"
cp "$root/LICENSE" "$root/NOTICE" "$root/THIRD_PARTY_LICENSES" "$stage/"
cp "$root/docs/BETA_INSTALL.md" "$stage/INSTALL.md"
cp "$root/BUILD_DEPENDENCIES.json" "$stage/"
# License files need exact contents, not downloaded-file metadata/ACLs.
python3 - "$root/docs/third-party" "$stage/third-party" <<'PYLICENSE'
from pathlib import Path
import sys
src,dst=map(Path,sys.argv[1:]);dst.mkdir()
for p in src.iterdir():
    if p.is_file(): (dst/p.name).write_bytes(p.read_bytes())
PYLICENSE
python3 - "$stage" "$revision" "$release" <<'PY'
from pathlib import Path
import sys,json,plistlib,subprocess
stage=Path(sys.argv[1]);app=stage/'boringNotch Codex.app';d=plistlib.loads((app/'Contents/Info.plist').read_bytes())
info={'release':sys.argv[3],'version':d['CFBundleShortVersionString'],'build':d['CFBundleVersion'],'source_commit':sys.argv[2],'source_repository':'https://github.com/y-k-g-cmd/boringNotch-Codex','source_tag':sys.argv[3],'architectures':['arm64','x86_64'],'minimum_macos':d['LSMinimumSystemVersion'],'signing':'ad-hoc','apple_notarized':False,'automatic_updates':False,'xcode':subprocess.check_output(['xcodebuild','-version'],text=True).strip()}
(stage/'BUILD-INFO.json').write_text(json.dumps(info,ensure_ascii=False,indent=2)+'\n')
PY
xattr -dr com.apple.FinderInfo "$stage/boringNotch Codex.app" 2>/dev/null || true
xattr -dr com.apple.ResourceFork "$stage/boringNotch Codex.app" 2>/dev/null || true
codesign --verify --deep --strict "$stage/boringNotch Codex.app"
ditto -c -k --norsrc --noextattr --keepParent "$stage" "$out/boringNotch-Codex-$release-universal.zip"
git -C "$root" archive --format=tar.gz --prefix=boringNotch-Codex-$release/ "$revision" -o "$out/boringNotch-Codex-$release-source.tar.gz"
cp "$stage/BUILD-INFO.json" "$out/BUILD-INFO.json"
cp "$stage/INSTALL.md" "$out/INSTALL.md"
(cd "$out" && shasum -a 256 boringNotch-Codex-$release-universal.zip boringNotch-Codex-$release-source.tar.gz BUILD-INFO.json INSTALL.md > SHA256SUMS.txt)
# Verify what recipients actually unpack, including symlink preservation.
mkdir "$scratch/verification"
ditto -x -k "$out/boringNotch-Codex-$release-universal.zip" "$scratch/verification"
codesign --verify --deep --strict "$scratch/verification/boringNotch-Codex-beta/boringNotch Codex.app"
echo "Prepared beta assets in $out"
