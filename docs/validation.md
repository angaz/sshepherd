# Native validation

## Automated checks

Run `scripts/build-android.sh` with the toolchain described in the README. It runs:

- Native libghostty-vt engine tests and host-JVM JNI integration.
- Rust transport and vendored protocol tests, including loopback QUIC replay/resume.
- Python PTY, input, resize, image-staging and quota tests.
- Kotlin/JUnit/Robolectric UI, input, host-store and content-lifecycle tests.
- Android assembly and lint for both supported native architectures.

The optional real-Herdr image test uses an isolated HOME/XDG/TMPDIR and a capture-only shell. It does not use deployment credentials or existing remote sessions.

## Artifact checks

- Verify the APK signature and 16 KB ELF/ZIP alignment.
- Confirm that APK assets contain only licenses, with no HTML/JavaScript/WASM UI.
- Check native libraries for embedded build-machine paths before distribution.
- Native build scripts remap Rust/C++ paths and strip terminal-library debug information. `scripts/check-artifact-privacy.py` rejects local home-directory paths in generated libraries and APKs.

APK/build/cache directories are ignored by Git. Native source, pinned dependency revisions, Gradle wrapper, Cargo/Nix locks, tests and build scripts are tracked.

## Manual checks

Automated tests do not establish physical-device rendering, OEM keyboard behavior, accessibility, connectivity or execution on a 16 KB-page-size device. See [device-checklist.md](device-checklist.md) for acceptance checks. No deployment-specific device-testing log is included.
