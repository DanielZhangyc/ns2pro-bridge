#!/bin/bash
set -euo pipefail
project_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$project_root"
python3 scripts/check-signing.py
swift build -c release --jobs 2
binary_path="$(swift build -c release --show-bin-path)"
app_path="$project_root/dist/NS2 Pro Bridge.app"
mkdir -p "$app_path/Contents/MacOS" "$app_path/Contents/Resources"
cp "$binary_path/NS2ProBridge" "$app_path/Contents/MacOS/NS2ProBridge"
cp Resources/Info.plist "$app_path/Contents/Info.plist"
cp LICENSE THIRD_PARTY_NOTICES.md "$app_path/Contents/Resources/"
cp Resources/IconSources/ATTRIBUTION.md "$app_path/Contents/Resources/ICON_ATTRIBUTION.md"
cp Resources/Controller/ns2-pro-front.png "$app_path/Contents/Resources/"
cp Resources/Controller/ATTRIBUTION.md "$app_path/Contents/Resources/CONTROLLER_ATTRIBUTION.md"
xcrun actool Resources/AppIcon.icon --compile "$app_path/Contents/Resources" \
    --platform macosx --minimum-deployment-target 26.0 --app-icon AppIcon \
    --output-partial-info-plist "$project_root/dist/icon-info.plist" --output-format human-readable-text
python3 scripts/check-signing.py --prepare "$app_path"
if [[ -n "${PROVISIONING_PROFILE:-}" ]]; then
    codesign --force --sign "$SIGN_IDENTITY" --entitlements dist/Signing.entitlements "$app_path"
else
    codesign --force --sign - "$app_path"
fi
codesign --verify --strict "$app_path"
printf 'Built (not launched): %s\n' "$app_path"
