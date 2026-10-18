#!/usr/bin/env python3
"""Validate Virtual HID provisioning before building; never ad-hoc sign restricted entitlements."""
import argparse
import datetime
import os
import pathlib
import plistlib
import shutil
import subprocess


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--prepare", type=pathlib.Path)
    args = parser.parse_args()
    profile_path = os.environ.get("PROVISIONING_PROFILE")
    identity = os.environ.get("SIGN_IDENTITY")
    root = pathlib.Path(__file__).resolve().parent.parent
    info = plistlib.loads((root / "Resources/Info.plist").read_bytes())
    entitlements = None
    if profile_path:
        if not identity or identity == "-":
            parser.error("PROVISIONING_PROFILE requires a real SIGN_IDENTITY, not ad-hoc signing")
        profile = plistlib.loads(subprocess.check_output(["security", "cms", "-D", "-i", profile_path]))
        granted = profile.get("Entitlements", {})
        if granted.get("com.apple.developer.hid.virtual.device") is not True:
            parser.error("The profile does not grant com.apple.developer.hid.virtual.device")
        expiry = profile.get("ExpirationDate")
        if not isinstance(expiry, datetime.datetime) or expiry.replace(tzinfo=datetime.timezone.utc) <= datetime.datetime.now(datetime.timezone.utc):
            parser.error("The provisioning profile is expired or lacks an expiration date")
        team = granted.get("com.apple.developer.team-identifier")
        identifier = granted.get("com.apple.application-identifier")
        if not team or identifier != team + "." + info["CFBundleIdentifier"]:
            parser.error("The provisioning profile must match this exact macOS app identifier")
        entitlements = plistlib.loads((root / "Resources/Bridge.entitlements").read_bytes())
        entitlements["com.apple.developer.team-identifier"] = team
        entitlements["com.apple.application-identifier"] = identifier
    elif identity:
        parser.error("SIGN_IDENTITY alone cannot grant Virtual HID; supply PROVISIONING_PROFILE")
    else:
        print("UNPROVISIONED BUILD: app can open, but controller connection is disabled. Virtual HID approval is required.")

    if args.prepare:
        contents = args.prepare / "Contents"
        profile_target = contents / "embedded.provisionprofile"
        info["NS2VirtualHIDProvisioned"] = entitlements is not None
        (contents / "Info.plist").write_bytes(plistlib.dumps(info))
        if entitlements is not None:
            shutil.copyfile(profile_path, profile_target)
            (root / "dist/Signing.entitlements").write_bytes(plistlib.dumps(entitlements))
        else:
            profile_target.unlink(missing_ok=True)
            (root / "dist/Signing.entitlements").unlink(missing_ok=True)


if __name__ == "__main__":
    main()
