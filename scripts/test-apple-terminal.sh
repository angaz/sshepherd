#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
./scripts/prepare-ghostty.sh
zig_bin=${ZIG_BIN:-zig}
[[ "$("$zig_bin" version)" == 0.16.0 ]] || { echo 'Zig 0.16.0 is required' >&2; exit 1; }
(cd .deps/libghostty-vt && "$zig_bin" build -Demit-lib-vt -Dsimd=false -Doptimize=Debug --prefix "$PWD/../ghostty-host")
cxx=${CXX:-c++}
common=(-std=c++17 -O0 -Wall -Wextra -Wno-missing-field-initializers -I.deps/libghostty-vt/include terminal/engine.cpp)
"$cxx" "${common[@]}" terminal/engine_test.cpp .deps/ghostty-host/lib/libghostty-vt.a -o .deps/apple-engine-test
"$cxx" "${common[@]}" terminal/apple.cpp terminal/apple_test.cpp .deps/ghostty-host/lib/libghostty-vt.a -pthread -o .deps/apple-terminal-test
set +e
python3 - .deps/apple-engine-test <<'PY'
import subprocess, sys
try:
    result = subprocess.run([sys.argv[1]], timeout=30)
except subprocess.TimeoutExpired:
    print("FAILED: Apple engine test exceeded its 30 second wall-clock bound", file=sys.stderr)
    raise SystemExit(124)
raise SystemExit(result.returncode)
PY
engine_status=$?
set -e
python3 - .deps/apple-terminal-test <<'PY'
import subprocess, sys
try:
    result = subprocess.run([sys.argv[1]], timeout=30)
except subprocess.TimeoutExpired:
    print("FAILED: Apple ABI test exceeded its 30 second wall-clock bound", file=sys.stderr)
    raise SystemExit(124)
raise SystemExit(result.returncode)
PY
exit "$engine_status"
