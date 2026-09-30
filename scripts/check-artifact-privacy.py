#!/usr/bin/env python3
"""Reject local build paths in generated native libraries or APK entries."""
import argparse
import os
from pathlib import Path
import re
import zipfile

HOME_PATH = re.compile(rb"/(?:home|Users)/[^/\x00\s]+/|[A-Za-z]:[\\/]Users[\\/][^\\/\x00\s]+[\\/]")


def local_prefixes():
    values = [str(Path(__file__).resolve().parent.parent), str(Path.home())]
    values += [os.environ[key] for key in ("CARGO_HOME", "RUSTUP_HOME", "ANDROID_NDK_HOME") if os.environ.get(key)]
    # Do not reject a whole filesystem when HOME happens to be its root.
    return [os.fsencode(value.rstrip("/\\") + "/") for value in values if value.rstrip("/\\")]


def contains_local_path(data, prefixes):
    # Also catch ASCII path components in UTF-16 LE/BE metadata strings.
    return any(HOME_PATH.search(value) or any(prefix in value for prefix in prefixes)
               for value in (data, data.replace(b"\0", b"")))


def check(path, prefixes):
    if path.suffix.lower() == ".apk":
        with zipfile.ZipFile(path) as archive:
            return [entry.filename for entry in archive.infolist()
                    if contains_local_path(os.fsencode(entry.filename), prefixes)
                    or (not entry.is_dir() and contains_local_path(archive.read(entry), prefixes))]
    return [path.name] if contains_local_path(path.read_bytes(), prefixes) else []


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("artifacts", type=Path, nargs="+")
    args = parser.parse_args()
    failures = 0
    for path in args.artifacts:
        entries = check(path, local_prefixes())
        if entries:
            failures += 1
            # Do not reproduce the embedded identifying paths in build logs.
            print(f"FAIL: {path.name}: local build paths in {len(entries)} entries")
        else:
            print(f"PASS: {path.name}: no local build paths")
    return bool(failures)


if __name__ == "__main__":
    raise SystemExit(main())
