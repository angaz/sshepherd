#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
: "${ZIG_BIN:=zig}"
command -v "$ZIG_BIN" >/dev/null || { echo "Zig 0.16.0 is required; use nix-shell scripts/ios-tools.nix." >&2; exit 2; }
ZIG_BIN="$ZIG_BIN" ./scripts/build-ios-native.sh

runtime=${IOS_SIMULATOR_RUNTIME:-iOS 26.3}
device=${IOS_SIMULATOR_DEVICE:-iPhone 17 Pro}
export IOS_SIMULATOR_RUNTIME="$runtime" IOS_SIMULATOR_DEVICE="$device"
udid=$(xcrun simctl list devices available --json | python3 -c 'import json,sys,os
v=json.load(sys.stdin)["devices"]
runtime=os.environ.get("IOS_SIMULATOR_RUNTIME","iOS 26.3").replace(" ","-").replace(".","-")
name=os.environ.get("IOS_SIMULATOR_DEVICE","iPhone 17 Pro")
for key, devices in v.items():
    if runtime in key:
        for d in devices:
            if d["name"] == name and d.get("isAvailable", False): print(d["udid"]); raise SystemExit
raise SystemExit("requested simulator is not installed")')

derived="$PWD/.deps/ios-derived"
# The simulator needs an ad-hoc signature for app-scoped Keychain access; no team is required.
xcodebuild -project ios/SSHepherd.xcodeproj -scheme SSHepherd -configuration Debug -sdk iphonesimulator \
  -destination "platform=iOS Simulator,id=$udid" -derivedDataPath "$derived" \
  CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=- ONLY_ACTIVE_ARCH=YES build
xcrun simctl boot "$udid" 2>/dev/null || true
xcrun simctl bootstatus "$udid" -b
app="$derived/Build/Products/Debug-iphonesimulator/SSHepherd.app"
# Without a launch screen iOS runs the app at a scaled legacy iPhone resolution.
python3 - "$app/Info.plist" <<'PY'
import plistlib, sys
with open(sys.argv[1], 'rb') as file:
    info = plistlib.load(file)
assert isinstance(info.get('UILaunchScreen'), dict), 'Modern iPhone launch screen is missing'
PY
xcrun simctl install "$udid" "$app"
xcrun simctl launch --terminate-running-process "$udid" io.angaz.sshepherd.ios
# A successful launch proves dyld found the real native XCFramework and all package products.
sleep 2
xcrun simctl spawn "$udid" launchctl print system >/dev/null
xcrun simctl terminate "$udid" io.angaz.sshepherd.ios
printf 'Built, installed, and launched SSHepherd on %s (%s), runtime %s.\n' "$device" "$udid" "$runtime"
