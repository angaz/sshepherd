#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
rev=14351f121f6fc8c84b7c6c6eda78ad210e93cfcb
sha=4d8b7a64277a4c33eda9fe2944148941d9fb8431d0bc25cdb96dd9bb262f681c
if [[ -f .deps/libghostty-vt/.sshepherd-source-$rev ]]; then exit 0; fi
mkdir -p .deps
archive=.deps/herdr-$rev.tar.gz
curl --fail --location --retry 3 "https://codeload.github.com/herdrdev/herdr/tar.gz/$rev" -o "$archive"
if command -v sha256sum >/dev/null && sha256sum --version >/dev/null 2>&1; then
  printf '%s  %s\n' "$sha" "$archive" | sha256sum -c -
else
  printf '%s  %s\n' "$sha" "$archive" | shasum -a 256 -c -
fi
mkdir -p .deps/libghostty-vt
tar -xzf "$archive" --strip-components=3 -C .deps/libghostty-vt "herdr-$rev/vendor/libghostty-vt"
touch ".deps/libghostty-vt/.sshepherd-source-$rev"
