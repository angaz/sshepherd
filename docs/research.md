# Native architecture and compatibility

The app uses no WebView/ghostty-web fallback. The current app uses standard Android Kotlin Views, a Canvas renderer and **native libghostty-vt through C++ JNI**. There is no HTML/JS/WASM or browser dependency in the APK.

## Server requirements

Configure trusted server endpoints and credentials locally; no deployment inventory is bundled.

## Native Ghostty integration

Source: the `vendor/libghostty-vt` tree bundled in [Herdr revision 14351f121f6fc8c84b7c6c6eda78ad210e93cfcb](https://github.com/herdrdev/herdr/tree/14351f121f6fc8c84b7c6c6eda78ad210e93cfcb/vendor/libghostty-vt). The download is pinned by revision and SHA-256 in `scripts/prepare-ghostty.sh`.

The source requires **Zig 0.16.0** and includes native Android NDK support in its `GhosttyLibVt.zig` build path. Build targets are `aarch64-linux-android.26` and `x86_64-linux-android.26`. The native static library is linked with the C++ bridge using Android NDK 28, with 16 KB segment alignment and no unresolved link symbols. The C++ standard library is statically linked; only Android libc/libm/libdl are dynamic terminal-library dependencies.

The C API supplies:

- Terminal VT parsing/state, alternate screen and resize/reflow.
- Render-state rows, cells, resolved palette/RGB colours, Unicode grapheme text, cell width, style and cursor.
- Keyboard encoding using current terminal modes; Android layout-consumed modifiers are normalized before encoding.
- Mouse press/release/motion encoding using actual cell pixel geometry and requested reporting format.
- PTY query reply callbacks, size reports and device attributes.

Kotlin owns native handles through a validated JNI registry and draws the copied cell snapshot with Android Canvas. Snapshot and reply buffers are bounded. No terminal parser is implemented in Kotlin. Clipboard/desktop side effects are intentionally not registered. The libghostty C API is still evolving, which is why the exact source revision is pinned.

Upstream context: [Ghostty](https://github.com/ghostty-org/ghostty), [libghostty announcement](https://mitchellh.com/writing/libghostty-is-coming), [Android embedding discussion](https://github.com/ghostty-org/ghostty/discussions/10902). The actual pinned source/build and native tests, not search snippets, establish the integration used here.

## Herdr Eternal

Pinned protocol source: [Mic92/herdr-eternal 28342f2854ce916724771072c51b432a4a3ec24a](https://github.com/Mic92/herdr-eternal/tree/28342f2854ce916724771072c51b432a4a3ec24a). `native/vendor/eternal-proto` preserves that source with its MIT license. Protocol is postcard framing over QUIC with `herdr-eternal/1` ALPN, Hello/Welcome, Exec/Resume and sequence/ACK replay. It is not HTTP/3 or SSH.

Herdr's `remote-client-bridge` is a private binary renderer protocol, not an ANSI stream. Instead, the existing Herdr frontend runs in an in-memory Python-created remote PTY, giving Ghostty real terminal output and retaining Herdr's native tabs/panes/mouse routing. No additional server service is required.

The trust policy requires explicit consent and independently authenticated server identity because server certificates are not verified. Destinations are restricted to allowed address ranges. Certificate pinning and OIDC are not implemented.
