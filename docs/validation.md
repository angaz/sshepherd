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

The native-backed Android link test passes when OSC 8 metadata is present. The API fallback now retrieves the destination using existing `pane.link.activate`, without changing Herdr's configuration or mouse-capture policy. Herdr's `pane.read`/`pane.get` revisions are placeholders in this version, so a passive `pane.copy_motion` query supplies the real content-revision token used by activation; it does not move the cursor or enter copy mode. A visible-only text read verifies the tapped row without scrolling or history harvesting.

`SSHEPHERD_TEST_HERDR_LINKS=1 python3 -m unittest discover -s tests -p test_herdr_links.py -v` starts an isolated real Herdr behind the actual framed PTY bridge. With mouse capture enabled it verifies the terminal stream omits the destination, the link API returns it, and subsequent mouse press/release still reaches the pane. It never controls the user's existing session.

Bridge tests cover geometry/text/focus/scroll/revision rejection, duplicate rows, wide-cell columns, missing APIs, plugin handling and uncertain activation (never retried). Native-backed Canvas tests cover stripped-label API requests, header-adjusted coordinates, HTTP(S) intent dispatch, mouse fallback, plugin/unsafe/error replies, stale replies after input/content/lifecycle changes, drags and cancellation. No Herdr changes are deployed. Physical-phone behavior remains a manual check; the API fallback deliberately excludes split/unrecognized layouts and lines above its 768-byte matching limit.

## Manual checks

Automated tests do not establish physical-device rendering, OEM keyboard behavior, accessibility, connectivity or execution on a 16 KB-page-size device. See [device-checklist.md](device-checklist.md) for acceptance checks. No deployment-specific device-testing log is included.
