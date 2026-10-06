#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
if ! command -v xcodebuild >/dev/null 2>&1; then
    echo "This script requires macOS with Xcode. It cannot build an iOS IPA on Windows/Linux."
    exit 1
fi
LAB_FIXTURE="$PWD/Tests/Fixtures/h264-60fps-aac48.mp4" swift test
xcodebuild -project HAMODYBRTikTokLab.xcodeproj \
    -scheme HAMODYBRTikTokLab -configuration Release \
    -sdk iphoneos -destination 'generic/platform=iOS' \
    -derivedDataPath build/DerivedData \
    CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY='' \
    build
python3 - <<'PY'
import plistlib
from pathlib import Path
app = Path('build/DerivedData/Build/Products/Release-iphoneos/HAMODYBRTikTokLab.app')
with (app / 'Info.plist').open('rb') as f:
    info = plistlib.load(f)
assert info.get('UIFileSharingEnabled') is True, 'Files sharing key missing or not a boolean'
assert info.get('LSSupportsOpeningDocumentsInPlace') is True, 'Documents provider key missing or not a boolean'
assert (app / 'Sample-60fps.mp4').stat().st_size > 0, 'Bundled sample is missing'
print('Verified Files integration keys and bundled sample in the device build.')
PY
mkdir -p build/Payload
rm -rf build/Payload/HAMODYBRTikTokLab.app
cp -R build/DerivedData/Build/Products/Release-iphoneos/HAMODYBRTikTokLab.app build/Payload/
rm -f build/HAMODYBR-TikTok-Lab-unsigned.ipa
(cd build && zip -qry HAMODYBR-TikTok-Lab-unsigned.ipa Payload)
echo "Built: build/HAMODYBR-TikTok-Lab-unsigned.ipa — sign it in Feather before installing."
