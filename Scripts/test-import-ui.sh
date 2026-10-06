#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
xcrun simctl list devices available -j > /tmp/hamodybr-simulators.json
SIMULATOR_ID=$(python3 - <<'PY'
import json
with open('/tmp/hamodybr-simulators.json') as f: data=json.load(f)
choices=[(runtime,d) for runtime,devices in data['devices'].items() for d in devices if d.get('isAvailable') and d['name'].startswith('iPhone')]
choices.sort(key=lambda x: (('iOS-18-5' in x[0]),x[1]['name']=='iPhone 16',x[0]),reverse=True)
if not choices: raise SystemExit('No iPhone simulator available')
print(choices[0][1]['udid'])
PY
)
xcodebuild -project HAMODYBRTikTokLab.xcodeproj \
    -scheme HAMODYBRTikTokLab -configuration Debug \
    -destination "platform=iOS Simulator,id=$SIMULATOR_ID" \
    -parallel-testing-enabled NO \
    -derivedDataPath build/Simulator \
    -resultBundlePath build/ImportSmoke.xcresult \
    CODE_SIGNING_ALLOWED=NO test
