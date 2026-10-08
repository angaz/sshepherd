#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
# Only a fresh simulator, generated test host key, and temp authorized_keys are touched.
fixture=$(mktemp -d "${TMPDIR:-/tmp}/sshepherd-ui-ssh.XXXXXX")
chmod 700 "$fixture"
device=""; pid=""
cleanup() {
  if [[ -n "$device" ]]; then
    xcrun simctl terminate "$device" io.angaz.sshepherd.ios >/dev/null 2>&1 || true
    xcrun simctl shutdown "$device" >/dev/null 2>&1 || true
    xcrun simctl delete "$device" >/dev/null 2>&1 || true
  fi
  if [[ -n "$pid" ]]; then kill "$pid" 2>/dev/null || true; wait "$pid" 2>/dev/null || true; fi
  rm -rf "$fixture"
}
trap cleanup EXIT INT TERM
sshd_bin=$(command -v sshd)
host=$(ifconfig | awk '/inet /{print $2}' | grep -E '^(10\.|192\.168\.|172\.(1[6-9]|2[0-9]|3[01])\.|100\.(6[4-9]|[7-9][0-9]|1[01][0-9]|12[0-7])\.)' | head -1)
[[ -n "$host" ]] || { echo 'BLOCKED: a private fixture address is required'; exit 2; }
port=$(python3 - "$host" <<'PY'
import socket,sys
s=socket.socket(); s.bind((sys.argv[1],0)); print(s.getsockname()[1]); s.close()
PY
)
device=$(xcrun simctl create 'SSHepherd end-to-end SSH fixture' com.apple.CoreSimulator.SimDeviceType.iPhone-16 com.apple.CoreSimulator.SimRuntime.iOS-26-3)
xcrun simctl boot "$device"
xcrun simctl bootstatus "$device" -b >"$fixture/boot.log" 2>&1
ssh-keygen -q -t ed25519 -N '' -f "$fixture/host_key"
fingerprint=$(ssh-keygen -lf "$fixture/host_key.pub" | awk '{print $2}')
xcodebuild -project ios/SSHepherd.xcodeproj -scheme SSHepherdInteractionTests -sdk iphonesimulator \
  -destination "platform=iOS Simulator,id=$device" -derivedDataPath .deps/ios-derived \
  CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=- ONLY_ACTIVE_ARCH=YES \
  test >"$fixture/uikit.log" 2>&1 || { tail -80 "$fixture/uikit.log"; exit 1; }
grep -E 'Executed .*tests.*0 failures' "$fixture/uikit.log" | tail -1
xcodebuild -project ios/SSHepherd.xcodeproj -scheme SSHepherdUITests -sdk iphonesimulator \
  -destination "platform=iOS Simulator,id=$device" -derivedDataPath .deps/ios-derived \
  CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=- ONLY_ACTIVE_ARCH=YES \
  build-for-testing >"$fixture/build.log" 2>&1 || { tail -80 "$fixture/build.log"; exit 1; }
app="$PWD/.deps/ios-derived/Build/Products/Debug-iphonesimulator/SSHepherd.app"
xcrun simctl install "$device" "$app"
container=$(xcrun simctl get_app_container "$device" io.angaz.sshepherd.ios data)
id=$(python3 - "$container" "$host" "$port" "$(id -un)" "$fingerprint" <<'PY'
import json,pathlib,sys,uuid
id=str(uuid.uuid4()).upper()
p=pathlib.Path(sys.argv[1])/'Library/Application Support/SSHepherd'; p.mkdir(parents=True,exist_ok=True)
(p/'servers.json').write_text(json.dumps([dict(id=id,name='Isolated UI fixture '+sys.argv[5],hostname=sys.argv[2],port=int(sys.argv[3]),username=sys.argv[4],authentication='ed25519')]))
print(id)
PY
)
xcrun simctl launch --terminate-running-process "$device" io.angaz.sshepherd.ios --prepare-public-key "$id" >/dev/null
public="$container/Library/Application Support/SSHepherd/simulator-public-key-$id.pub"
for _ in {1..50}; do [[ -f "$public" ]] && break; sleep .1; done
[[ -f "$public" ]] || { echo 'FAILED: app-side Keychain public-key provisioning'; exit 1; }
cp "$public" "$fixture/authorized_keys"; chmod 600 "$fixture/authorized_keys"
mkdir "$fixture/home"
cat >"$fixture/shell-fixture.sh" <<EOF
#!/bin/sh
[ "\$SSH_ORIGINAL_COMMAND" = 'herdr --session default' ] || exit 1
stty -echo
export HOME='$fixture/home'
cd "\$HOME"
printf 'UI_FIXTURE_READY\\n'
exec /bin/sh -i
EOF
chmod 700 "$fixture/shell-fixture.sh"
cat >"$fixture/sshd_config" <<EOF
HostKey $fixture/host_key
AuthorizedKeysFile $fixture/authorized_keys
PidFile $fixture/sshd.pid
Port $port
ListenAddress $host
PasswordAuthentication no
KbdInteractiveAuthentication no
PubkeyAuthentication yes
UsePAM no
PermitRootLogin no
StrictModes no
AllowUsers $(id -un)
AllowAgentForwarding no
AllowTcpForwarding no
X11Forwarding no
PermitTunnel no
GatewayPorts no
ForceCommand $fixture/shell-fixture.sh
LogLevel VERBOSE
EOF
"$sshd_bin" -t -f "$fixture/sshd_config"
"$sshd_bin" -D -e -f "$fixture/sshd_config" >"$fixture/sshd.log" 2>&1 & pid=$!
for _ in {1..50}; do grep -q 'Server listening' "$fixture/sshd.log" && break; sleep .1; done
grep -q 'Server listening' "$fixture/sshd.log" || { tail -30 "$fixture/sshd.log"; exit 1; }
xcodebuild -project ios/SSHepherd.xcodeproj -scheme SSHepherdUITests -sdk iphonesimulator \
  -destination "platform=iOS Simulator,id=$device" -derivedDataPath .deps/ios-derived \
  CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=- ONLY_ACTIVE_ARCH=YES \
  test-without-building >"$fixture/test.log" 2>&1 || { tail -80 "$fixture/test.log"; exit 1; }
accepted=$(grep -c 'Accepted publickey' "$fixture/sshd.log" || true)
[[ "$accepted" == 3 ]] || { echo "FAILED: expected initial SSH attachment, manual reconnect and cold-launch automatic reconnect, got $accepted"; exit 1; }
echo 'PASS: real app taps, fingerprint approval, device-only key, typing, control keys, manual reconnect and remembered-server cold launch through isolated stock OpenSSH (no production session)'
