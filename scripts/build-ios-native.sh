#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
./scripts/prepare-ghostty.sh
source scripts/native-path-flags.sh
if [[ ! -x "${DEVELOPER_DIR:-}/usr/bin/xcodebuild" ]]; then
  DEVELOPER_DIR=$(/usr/bin/xcode-select -p)
fi
export DEVELOPER_DIR
zig_bin=${ZIG_BIN:-zig}
[[ "$("$zig_bin" version)" == 0.16.0 ]] || { echo 'Zig 0.16.0 is required (nix-shell scripts/ios-tools.nix)' >&2; exit 1; }
root=$PWD
for sdk_name in iphoneos iphonesimulator macosx; do
  if [[ $sdk_name == iphoneos ]]; then
    zig_target=aarch64-ios
    clang_target=arm64-apple-ios13.0
    platform=IOS
  elif [[ $sdk_name == iphonesimulator ]]; then
    zig_target=aarch64-ios-simulator
    clang_target=arm64-apple-ios14.0-simulator
    platform=IOSSIMULATOR
  else
    zig_target=aarch64-macos
    clang_target=arm64-apple-macos13.0
    platform=MACOS
  fi
  sdk=$(xcrun --sdk "$sdk_name" --show-sdk-path)
  out="$root/.deps/apple-$sdk_name"
  mkdir -p "$out"
  (cd .deps/libghostty-vt && "$zig_bin" build -Demit-lib-vt -Dsimd=false -Dtarget="$zig_target" -Doptimize=ReleaseFast --prefix "$out/ghostty")
  xcrun --sdk "$sdk_name" clang++ -target "$clang_target" -std=c++17 -O2 -fPIC -fvisibility=hidden -isysroot "$sdk" \
    "${native_cpp_flags[@]}" -Wall -Wextra -Wno-missing-field-initializers -I.deps/libghostty-vt/include -c terminal/apple.cpp -o "$out/apple.o"
  xcrun --sdk "$sdk_name" clang++ -target "$clang_target" -std=c++17 -O2 -fPIC -fvisibility=hidden -isysroot "$sdk" \
    "${native_cpp_flags[@]}" -Wall -Wextra -Wno-missing-field-initializers -I.deps/libghostty-vt/include -c terminal/engine.cpp -o "$out/engine.o"
  /usr/bin/libtool -static -o "$out/libsshepherd_terminal.a" "$out/apple.o" "$out/engine.o" "$out/ghostty/lib/libghostty-vt.a"
  xcrun --sdk "$sdk_name" clang++ -target "$clang_target" -std=c++17 -O2 -isysroot "$sdk" -I.deps/libghostty-vt/include \
    terminal/apple_test.cpp "$out/libsshepherd_terminal.a" -o "$out/apple-terminal-test"
  xcrun vtool -show-build "$out/apple.o" | grep -F "platform $platform"
  extract="$out/ghostty-objects"
  rm -rf "$extract"; mkdir "$extract"
  (cd "$extract" && ar -x "$out/ghostty/lib/libghostty-vt.a" && chmod u+r ./*.o)
  ghostty_object=$(find "$extract" -name '*.o' -print -quit)
  xcrun vtool -show-build "$ghostty_object" | grep -F "platform $platform"
  xcrun vtool -show-build "$out/apple-terminal-test" | grep -F "platform $platform"
  printf '%s SDK=%s Zig=%s target=%s\n' "$sdk_name" "$sdk" "$("$zig_bin" version)" "$zig_target" > "$out/build-info.txt"
done
headers="$root/.deps/apple-headers"
rm -rf "$headers"; mkdir -p "$headers"
cp terminal/apple.h terminal/module.modulemap "$headers/"
artifact="$root/ios/AppCore/Native/SSHepherdTerminal.xcframework"
rm -rf "$artifact"; mkdir -p "$(dirname "$artifact")"
xcodebuild -create-xcframework \
  -library "$root/.deps/apple-iphoneos/libsshepherd_terminal.a" -headers "$headers" \
  -library "$root/.deps/apple-iphonesimulator/libsshepherd_terminal.a" -headers "$headers" \
  -library "$root/.deps/apple-macosx/libsshepherd_terminal.a" -headers "$headers" \
  -output "$artifact"
