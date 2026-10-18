#!/usr/bin/env python3
"""Bounded public-source checks; not a comprehensive secret-scanner certification."""
from pathlib import Path
import base64,json,plistlib,re,subprocess,sys
root=Path(__file__).resolve().parent.parent
skip={'.git','.local-build','.swiftpm','.build','DerivedData','build'}
patterns={
 'local-user-path': re.compile(rb'/Users/'+b'gsw/'),
 'private-key': re.compile(rb'-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----'),
 'github-token': re.compile(rb'gh[pousr]_[A-Za-z0-9]{30,}|github_pat_[A-Za-z0-9_]{35,}'),
 'openai-token': re.compile(rb'sk-(?:proj-)?[A-Za-z0-9_-]{40,}'),
 'aws-access-id': re.compile(rb'AKIA[0-9A-Z]{16}'),
}
issues=[]; scanned=0; binary=0
candidate_files = (subprocess.check_output(['git','-C',str(root),'ls-files','--cached','--others','--exclude-standard','-z']).split(b'\0')
                   if (root/'.git').exists() else [str(p.relative_to(root)).encode() for p in root.rglob('*')])
for name in candidate_files:
 if not name: continue
 rel=Path(name.decode())
 p=root/rel
 if any(part in skip for part in rel.parts) or p.is_symlink() or not p.is_file():continue
 if p.name in {'auth.json','credentials.json','mirrors.json'} or p.suffix in {'.p12','.p8','.pem','.key','.log','.xcuserstate'} or 'xcuserdata' in rel.parts:issues.append((str(rel),'excluded-runtime-or-secret-file'))
 data=p.read_bytes();scanned+=1
 if b'\0' in data:binary+=1
 for name,pattern in patterns.items():
  if pattern.search(data):issues.append((str(rel),name))
info=plistlib.loads((root/'boringNotch/Info.plist').read_bytes())
repo='https://github.com/y-k-g-cmd/boringNotch-Codex'
if info.get('ForkRepositoryURL')!=repo:issues.append(('Info.plist','unexpected-repository'))
if info.get('ForkUpdatesEnabled'):
 try:valid=info.get('SUFeedURL')=='https://y-k-g-cmd.github.io/boringNotch-Codex/appcast.xml' and len(base64.b64decode(info.get('SUPublicEDKey',''),validate=True))==32
 except Exception:valid=False
 if not valid:issues.append(('Info.plist','invalid-fork-update-configuration'))
elif 'SUFeedURL' in info or 'SUPublicEDKey' in info:issues.append(('Info.plist','disabled-channel-still-has-update-credentials'))
lock=json.loads((root/'boringNotch.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved').read_text())
pins=json.loads((root/'BUILD_DEPENDENCIES.json').read_text())
if {p['identity']:p['state']['revision'] for p in lock['pins']}!={p['identity']:p['revision'] for p in pins}:issues.append(('Package.resolved','dependency-lock-mismatch'))
for name in ['README.md','LICENSE','THIRD_PARTY_LICENSES','BUILDING.md','PRIVACY.md','SECURITY.md','CHANGELOG.md']:
 if not (root/name).is_file():issues.append((name,'missing-required-file'))
for p in (root/'.github/workflows').glob('*'):
 text=p.read_text()
 if any(s in text for s in ['pull_request_target','issue_comment','contents: write','CORI_APP','OPENAI_API_KEY','BUILD_CERTIFICATE_BASE64']):issues.append((str(p.relative_to(root)),'unexpected-publishing-or-secret-workflow'))
print(f'Checked {scanned} source-tree files ({binary} contain binary data); fixed credential/path heuristics only.')
for path,reason in issues:print(f'FAIL {path}: {reason}')
if issues:sys.exit(1)
print('PASS: public tree exclusions, known credential/path patterns, isolated update configuration and dependency lock')
