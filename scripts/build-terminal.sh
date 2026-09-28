#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
./scripts/prepare-ghostty.sh
: "${ANDROID_NDK_HOME:?Set ANDROID_NDK_HOME}"
[[ "$(zig version)" == 0.16.0 ]] || { echo 'Zig 0.16.0 is required' >&2; exit 1; }
root=$PWD
case "$(uname -s)" in
  Linux) host=linux-x86_64;;
  Darwin) host=darwin-x86_64;;
  *) echo 'Use Linux or macOS to build native libraries' >&2; exit 1;;
esac
bin="$ANDROID_NDK_HOME/toolchains/llvm/prebuilt/$host/bin"
for abi in arm64-v8a x86_64; do
  if [[ $abi == arm64-v8a ]]; then arch=aarch64; else arch=x86_64; fi
  prefix="$root/.deps/ghostty-$abi"
  (cd .deps/libghostty-vt && zig build -Demit-lib-vt -Dsimd=false -Dtarget="$arch-linux-android.26" -Doptimize=ReleaseFast --prefix "$prefix")
  mkdir -p "android/app/src/main/jniLibs/$abi"
  "$bin/${arch}-linux-android26-clang++" -std=c++17 -O2 -fPIC -fvisibility=hidden \
    -Wall -Wextra -Wno-missing-field-initializers -shared -static-libstdc++ \
    -Wl,-z,max-page-size=16384 -Wl,--no-undefined -Wl,--exclude-libs,ALL \
    -I.deps/libghostty-vt/include terminal/engine.cpp terminal/jni.cpp \
    "$prefix/lib/libghostty-vt.a" -o "android/app/src/main/jniLibs/$abi/libsshepherd_terminal.so"
done
mkdir -p android/app/src/main/assets/licenses
cp .deps/libghostty-vt/LICENSE android/app/src/main/assets/licenses/libghostty-vt.txt
