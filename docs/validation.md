# Native validation

## Automated checks

Run `scripts/build-android.sh` with the toolchain described in the README. It runs:

- Native libghostty-vt engine tests and host-JVM JNI integration.
- Rust transport and vendored protocol tests, including loopback QUIC replay/resume.
- Python PTY, input, resize, image-staging and quota tests.
- Kotlin/JUnit/Robolectric UI, input, host-store and content-lifecycle tests, including an OSC 8 labeled link fed through the real host JNI engine and Canvas view's touch dispatch. Run native tests first to provide `.deps/libsshepherd_terminal.so`.
- Android assembly and lint for both supported native architectures.

The optional real-Herdr test (`SSHEPHERD_TEST_HERDR=/absolute/path/to/herdr python3 -m unittest discover -s tests -v`) covers project listing, workspace creation/focus, passive scrollback capture and image paste. It uses an isolated HOME/XDG/TMPDIR and a capture-only shell, never deployment credentials or existing remote sessions.

Project-picker tests cover discovery depth, worktrees, path traversal/symlink containment, unsupported names, search and duplicate/uncertain creation guards. Scratchpad tests cover passive API parameters, ANSI stripping, Unicode/size/line bounds, native selection/copy/editing, late replies, discard confirmation and retention across automatic detach.

## Artifact checks

- Verify the APK signature and 16 KB ELF/ZIP alignment.
- Confirm that APK assets contain only licenses, with no HTML/JavaScript/WASM UI.
- Check native libraries for embedded build-machine paths before distribution.
- Native build scripts remap Rust/C++ paths and strip terminal-library debug information. `scripts/check-artifact-privacy.py` rejects local home-directory paths in generated libraries and APKs.

APK/build/cache directories are ignored by Git. Native source, pinned dependency revisions, Gradle wrapper, Cargo/Nix locks, tests and build scripts are tracked.

## Labeled-link diagnosis

An isolated installed Herdr 0.9.4 client was fed an OSC 8 link labeled `Open example.com` with destination `https://example.com`. With default mouse capture, captured client output rendered the label but omitted the destination. Repeating with `[ui].mouse_capture = false` emitted the destination. In Herdr's `src/client/state.rs`, `try_present_frame_to` explicitly clears `frame_data.hyperlinks` when `shell_mouse_capture_preference` is enabled, to prevent host Ctrl-click from bypassing plugins.

The native-backed Android link test passes when OSC 8 metadata is present. This narrows the reproduced loss to Herdr's presentation policy, not URI decoding or Android intent dispatch. No shared Herdr configuration was changed, no Herdr fix was deployed, and phone behavior is not yet validated. A fix must preserve mouse controls while allowing this frontend to receive link metadata.

## Manual checks

Automated tests do not establish physical-device rendering, OEM keyboard behavior, accessibility, connectivity or execution on a 16 KB-page-size device. See [device-checklist.md](device-checklist.md) for acceptance checks. No deployment-specific device-testing log is included.
