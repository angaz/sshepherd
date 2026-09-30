#!/usr/bin/env bash
# Source from native build scripts after changing to the repository root.
# Encoded flags keep paths with spaces intact and preserve caller-supplied flags.
if [[ ${CARGO_ENCODED_RUSTFLAGS+x} ]]; then
  native_rust_flags=$CARGO_ENCODED_RUSTFLAGS
else
  native_rust_args=()
  read -r -a native_rust_args <<< "${RUSTFLAGS:-}"
  printf -v native_rust_flags '%s\x1f' "${native_rust_args[@]}"
  native_rust_flags=${native_rust_flags%$'\x1f'}
fi
native_cpp_flags=(-g0)
native_prefixes=(
  "${HOME:?}=/build/user"
  "${CARGO_HOME:-$HOME/.cargo}=/build/cargo"
  "${RUSTUP_HOME:-$HOME/.rustup}=/build/rustup"
  "/nix/store=/build/tools"
)
if [[ -n ${ANDROID_NDK_HOME:-} ]]; then
  native_prefixes+=("$ANDROID_NDK_HOME=/build/ndk")
fi
# Rust uses the last matching prefix; the checkout should have highest priority.
native_prefixes+=("$PWD=/build/source")
for native_mapping in "${native_prefixes[@]}"; do
  native_rust_flags+="${native_rust_flags:+$'\x1f'}--remap-path-prefix=$native_mapping"
  native_cpp_flags+=("-ffile-prefix-map=$native_mapping")
done
export CARGO_ENCODED_RUSTFLAGS=$native_rust_flags
# Development shells can inject an RPATH to a local, nonexistent output tree.
# Keep toolchain/library RPATHs, but never embed directories under HOME/checkout.
if [[ -n ${NIX_LDFLAGS:-} ]]; then
  export NIX_LDFLAGS
  NIX_LDFLAGS=$(python3 - "$HOME" "$PWD" <<'PY'
import os, shlex, sys
flags = iter(shlex.split(os.environ["NIX_LDFLAGS"]))
result = []
for flag in flags:
    if flag == "-rpath":
        path = next(flags)
        if any(path == root or path.startswith(root.rstrip("/") + "/") for root in sys.argv[1:]):
            continue
        result.extend((flag, path))
    else:
        result.append(flag)
print(shlex.join(result))
PY
)
fi
unset native_rust_args native_rust_flags native_prefixes native_mapping
