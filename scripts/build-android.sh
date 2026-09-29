#!/usr/bin/env bash
# Native-only build: Kotlin Views + Canvas, Rust QUIC, C++/Zig libghostty-vt.
set -euo pipefail
cd "$(dirname "$0")/.."
: "${ANDROID_HOME:?Set ANDROID_HOME to the Android SDK directory}"
: "${ANDROID_NDK_HOME:=$ANDROID_HOME/ndk/28.0.13004108}"
export ANDROID_NDK_HOME
command -v cargo-ndk >/dev/null || { echo 'Install cargo-ndk: cargo install cargo-ndk --version 4.1.2 --locked' >&2; exit 1; }
./scripts/test.sh
# Generated assets only: ensure the previous web prototype cannot be packaged.
mkdir -p android/app/src/main/assets
find android/app/src/main/assets -mindepth 1 -delete
./scripts/build-terminal.sh
mkdir -p android/app/src/main/assets/licenses
cp native/vendor/eternal-proto/LICENSE android/app/src/main/assets/licenses/herdr-eternal.txt
cp licenses/Apache-2.0.txt android/app/src/main/assets/licenses/material-androidx.txt
(cd native && RUSTFLAGS="${RUSTFLAGS:-} -C link-arg=-Wl,-z,max-page-size=16384" cargo ndk -t arm64-v8a -t x86_64 --platform 26 -o ../android/app/src/main/jniLibs build --release --locked)
(cd android && ./gradlew --no-daemon "-Pandroid.aapt2FromMavenOverride=$ANDROID_HOME/build-tools/35.0.0/aapt2" testDebugUnitTest assembleDebug lintDebug)
printf '\nNative APK: android/app/build/outputs/apk/debug/app-debug.apk\n'
