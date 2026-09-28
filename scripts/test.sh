#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
./scripts/test-terminal.sh
python3 -m unittest discover -s tests -v
cargo test --manifest-path native/Cargo.toml --locked
cargo test --manifest-path native/vendor/eternal-proto/Cargo.toml --locked
