# Native migration review

A fresh-context read-only reviewer inspected the Kotlin Activity/Canvas/InputConnection implementation, native Ghostty C++ wrapper/JNI ownership, snapshot decoder and Rust JNI seam. This was a bounded source review, not a diff-verified review against a committed baseline. Parent remained the sole writer.

All concrete findings were accepted and fixed:

1. **IME Enter ordering (P1):** editor actions and forwarded Enter-down now finish local composition first. Regression tests verify text precedes Enter and is sent once even if the IME later finishes composition again. Navigation/accessory actions also finish composition before changing remote state.
2. **Alt/AltGr layout handling (P1):** a tested `TerminalKeys` resolver preserves layout-selected Unicode and distinguishes consumed AltGr modifiers from terminal Alt shortcuts. Consumed modifiers cross JNI to Ghostty. Native tests exposed that Ghostty's legacy Ctrl path uses raw modifiers, so layout-consumed synthetic Ctrl/Alt are normalized before encoding as well. Native tests verify both AltGr `@` and terminal Alt+Q.
3. **Synthetic key release (P2):** IME-generated deletion/editor actions now send matched down/up pairs, compatible with Kitty event reporting. Tests assert both keycodes and actions. Actual forwarded key events retain their original action without synthesizing duplicates.

The reviewer found no concrete native-FFI crash blocker; handles are validated/serialized and snapshot lengths are bounded. The final test/build results are in `validation.md`. Android hardware keyboards/IMEs still require device checks.

Earlier transport fixes remain: cancellation-safe framing, acknowledged replay, final ACK/EOF drain, output-draining detach, and latest-geometry retry under backpressure. The earlier WebView rendering/input code and its tests have been removed rather than counted as native validation.
