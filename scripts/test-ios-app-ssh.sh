#!/bin/bash
set -euo pipefail
repo=$(cd "$(dirname "$0")/.." && pwd)
proof="$repo/ios/SSHProof"
app="$repo/ios/AppCore"
sshd_bin=$(command -v sshd || true)
if [[ -z "$sshd_bin" ]] || ! command -v ssh-keygen >/dev/null || ! command -v swift >/dev/null; then
  echo "BLOCKED: swift, sshd, and ssh-keygen are required" >&2; exit 2
fi
host=${APP_SSH_FIXTURE_ADDRESS:-$(ifconfig | awk '/inet /{print $2}' | grep -E '^(10\.|192\.168\.|172\.(1[6-9]|2[0-9]|3[01])\.|100\.(6[4-9]|[7-9][0-9]|1[01][0-9]|12[0-7])\.)' | head -1)}
[[ -n "$host" ]] || { echo "BLOCKED: no private non-loopback address is available for the production-filter integration test" >&2; exit 2; }
fixture=$(mktemp -d "${TMPDIR:-/tmp}/appssh.XXXXXX"); pid=""; pid2=""
cleanup() {
  for running in "$pid" "$pid2"; do
    if [[ -n "$running" ]] && kill -0 "$running" 2>/dev/null; then
      kill "$running" 2>/dev/null || true
      for _ in {1..50}; do kill -0 "$running" 2>/dev/null || break; sleep .1; done
      kill -9 "$running" 2>/dev/null || true
      wait "$running" 2>/dev/null || true
    fi
  done
  rm -rf "$fixture"
}
trap cleanup EXIT INT TERM
chmod 700 "$fixture"; mkdir "$fixture/home"; chmod 700 "$fixture/home"
ssh-keygen -q -t ed25519 -N '' -f "$fixture/host_key"
python3 - "$proof" "$fixture/keygen.out" "$fixture/keygen.log" <<'PY'
import subprocess, sys
with open(sys.argv[2], "wb") as output, open(sys.argv[3], "wb") as error:
    try:
        result = subprocess.run(["swift", "run", "-c", "debug", "SSHProofKeygen"], cwd=sys.argv[1], stdout=output, stderr=error, timeout=120)
    except subprocess.TimeoutExpired:
        print("FAILED: AppCore fixture key generator exceeded its 120 second wall-clock bound", file=sys.stderr)
        raise SystemExit(124)
raise SystemExit(result.returncode)
PY
{ IFS= read -r private; IFS= read -r public; } < "$fixture/keygen.out"
[[ -n "${private:-}" && -n "${public:-}" ]] || { echo "FAILED: fixture key generator output is incomplete" >&2; exit 1; }
printf '%s\n' "$public" > "$fixture/authorized_keys"; chmod 600 "$fixture/authorized_keys"
port=$(python3 -c "import socket; s=socket.socket(); s.bind(('$host',0)); print(s.getsockname()[1]); s.close()")
cat > "$fixture/sshd_config" <<EOF
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
LogLevel VERBOSE
EOF
"$sshd_bin" -t -f "$fixture/sshd_config"
HOME="$fixture/home" "$sshd_bin" -D -e -f "$fixture/sshd_config" >"$fixture/sshd.log" 2>&1 & pid=$!
for _ in {1..50}; do grep -q 'Server listening' "$fixture/sshd.log" && break; sleep .1; done
grep -q 'Server listening' "$fixture/sshd.log" || { tail -100 "$fixture/sshd.log" >&2; exit 1; }
no_tty_port=$(python3 -c "import socket; s=socket.socket(); s.bind(('$host',0)); print(s.getsockname()[1]); s.close()")
cat > "$fixture/sshd_no_tty_config" <<EOF
HostKey $fixture/host_key
AuthorizedKeysFile $fixture/authorized_keys
PidFile $fixture/sshd-no-tty.pid
Port $no_tty_port
ListenAddress $host
PasswordAuthentication no
KbdInteractiveAuthentication no
PubkeyAuthentication yes
UsePAM no
PermitRootLogin no
StrictModes no
AllowUsers $(id -un)
PermitTTY no
AllowAgentForwarding no
AllowTcpForwarding no
X11Forwarding no
PermitTunnel no
GatewayPorts no
LogLevel VERBOSE
EOF
"$sshd_bin" -t -f "$fixture/sshd_no_tty_config"
HOME="$fixture/home" "$sshd_bin" -D -e -f "$fixture/sshd_no_tty_config" >"$fixture/sshd-no-tty.log" 2>&1 & pid2=$!
for _ in {1..50}; do grep -q 'Server listening' "$fixture/sshd-no-tty.log" && break; sleep .1; done
grep -q 'Server listening' "$fixture/sshd-no-tty.log" || { tail -100 "$fixture/sshd-no-tty.log" >&2; exit 1; }
export APP_SSH_HOST="$host" APP_SSH_PORT="$port" APP_SSH_USER="$(id -un)"
export APP_SSH_HOST_KEY="$fixture/host_key.pub" APP_SSH_CLIENT_PRIVATE_KEY="$private"
export APP_SSH_NO_TTY_PORT="$no_tty_port" APP_SSH_NO_TTY_MARKER="$fixture/no-tty-exec-marker"
if ! python3 - "$app" "$fixture/test.log" <<'PY'
import os, subprocess, sys
with open(sys.argv[2], "wb") as log:
    # Keep a cold dependency compilation out of the test's runtime deadline.
    try:
        build = subprocess.run(["swift", "build", "--build-tests"], cwd=sys.argv[1], env=os.environ, stdout=log, stderr=subprocess.STDOUT, timeout=180)
    except subprocess.TimeoutExpired:
        print("FAILED: AppCore test build exceeded its 180 second wall-clock bound", file=sys.stderr)
        raise SystemExit(124)
    if build.returncode:
        raise SystemExit(build.returncode)
    try:
        result = subprocess.run(["swift", "test", "--skip-build"], cwd=sys.argv[1], env=os.environ, stdout=log, stderr=subprocess.STDOUT, timeout=60)
    except subprocess.TimeoutExpired:
        print("FAILED: AppCore SSH integration exceeded its 60 second wall-clock bound", file=sys.stderr)
        raise SystemExit(124)
raise SystemExit(result.returncode)
PY
then
  tail -200 "$fixture/test.log" >&2; exit 1
fi
accepted=$(grep -c 'Accepted publickey' "$fixture/sshd.log" || true)
[[ "$accepted" == 1 ]] || { echo "FAILED: expected one successful authentication, saw $accepted" >&2; tail -100 "$fixture/sshd.log" >&2; exit 1; }
no_tty_accepted=$(grep -c 'Accepted publickey' "$fixture/sshd-no-tty.log" || true)
[[ "$no_tty_accepted" == 1 && ! -e "$fixture/no-tty-exec-marker" ]] || {
  echo "FAILED: PermitTTY fixture did not reject before exec" >&2; tail -100 "$fixture/sshd-no-tty.log" >&2; exit 1;
}
echo "PASS: real NIOSSH streaming transport bounded trust/auth/request setup, streamed interactive bytes, resized, rejected changed/wrong credentials, and refused exec after PTY rejection"
