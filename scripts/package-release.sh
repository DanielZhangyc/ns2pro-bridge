#!/bin/bash
# 使用正式 Virtual HID 描述文件、Developer ID 身份和 notarytool 钥匙串配置。
# Set PROVISIONING_PROFILE, SIGN_IDENTITY, and NOTARY_PROFILE for distribution.
set -euo pipefail
project_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$project_root"
: "${NOTARY_PROFILE:?Set NOTARY_PROFILE to a notarytool keychain profile}"
python3 scripts/check-signing.py --distribution
bash scripts/build-app.sh
app_path="$project_root/dist/NS2 Pro Bridge.app"
signature="$(codesign --display --verbose=4 "$app_path" 2>&1)"
if ! [[ "$signature" == *"Authority=Developer ID Application:"* ]]; then
    echo "Release packaging requires a Developer ID Application signature." >&2
    exit 1
fi
version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app_path/Contents/Info.plist")"
archive="$project_root/dist/NS2-Pro-Bridge-$version-macOS.zip"
submission="$project_root/dist/notarization-submission.zip"
ditto -c -k --keepParent "$app_path" "$submission"
xcrun notarytool submit "$submission" --keychain-profile "$NOTARY_PROFILE" --wait --output-format plist > dist/notarization-result.plist
status="$(/usr/libexec/PlistBuddy -c 'Print :status' dist/notarization-result.plist)"
if [[ "$status" != "Accepted" ]]; then
    echo "Notarization was not accepted; see dist/notarization-result.plist." >&2
    exit 1
fi
xcrun stapler staple "$app_path"
xcrun stapler validate "$app_path"
codesign --verify --strict "$app_path"
spctl --assess --type execute --verbose=2 "$app_path"
ditto -c -k --keepParent "$app_path" "$archive"
(cd "$project_root/dist" && shasum -a 256 "$(basename "$archive")") > "$archive.sha256"
printf 'Notarized release archive (not uploaded): %s\n' "$archive"
