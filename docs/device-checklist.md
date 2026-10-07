# Native Android acceptance checklist

Automated native-engine/JNI and Robolectric tests do not replace on-device checks.

- [ ] Install the current APK over a previous debug build. Confirm native controls and no WebView/browser dependency.
- [ ] Launch offline: the empty host list appears; added hosts remain listed and retryable after connection failures. Offline connection failure leaves the host visible and retryable.
- [ ] Save shared token, relaunch and connect; Forget token makes the next connection request credentials. Confirm the server trust notice.
- [ ] Connect through mesh IPv6 UDP 7443 and verify existing `default` Herdr state.
- [ ] Tap and drag tab/pane controls and mouse-aware TUIs. Exactly one press/release pair, correctly aligned to cells; no stuck mouse on cancellation.
- [ ] Test Gboard and the preferred IME: suggestions, swipe typing, committed text, composition, Unicode/emoji, backspace at an empty local editor, Enter while composing, cancellation and paste. Commands must not be automatically capitalized.
- [ ] Take a screenshot and inspect the app-switcher preview: terminal/UI content should be visible, not blank.
- [ ] Test physical keyboard: Ctrl+C, Alt terminal shortcuts, AltGr/layout characters, dead keys, Shift+Tab, arrows in normal/application modes and Kitty-aware apps.
- [ ] Show/hide IME and rotate: terminal fits between native navigation/accessory rows; remote geometry updates even after input backpressure.
- [ ] Verify bold/italic/underline, RGB/palette colours, combining marks, CJK/emoji wide cells, cursor, alternate screen, full-screen TUI repaint.
- [ ] Use Attach with a UTF-8 text file and verify contents paste after confirmation, not a path. Cancel without sending anything.
- [ ] Paste an image via clipboard URI, keyboard image insertion and Attach; verify Herdr's remote image path reaches the intended pane and the agent can read it. Confirm ≤16 MiB/image and 64 MiB/session handling.
- [ ] Disconnect or leave the app while a content provider is reading; verify grants/streams are released and no stale upload reaches another session. Verify the 15-second provider timeout.
- [ ] Add/edit/delete a host using a friendly name and hostname or private IP; restart the app and verify persistence. Confirm compact cards show the address on the right and Workspaces stays visible at the top.
- [ ] Test a cold network/DNS start: first resolution timeout should retry automatically, while invalid/public destinations must fail without sending credentials.
- [ ] Verify Material cards/settings/dialogs and the compact terminal top bar. Verify the compact two-row shortcut bar keeps Ctrl and all four arrows visible without expanding; check Ctrl's highlighted latch and reset after input. Expand/collapse extra keys; verify bottom-right keyboard icon and all keys in portrait/landscape, with IME open and larger font settings. Check TalkBack labels and hardware focus navigation.
- [ ] Swipe Gboard's space bar left/right through phone-typed text; type at the new position and confirm correction/backspace still work. Terminal history outside retained text is not available to IME selection gestures.
- [ ] Switch tabs/workspaces and zoom with ctrl+a-based controls; pending composition commits before navigation.
- [ ] Temporarily disable VPN during output; restore it and confirm replay without duplicate output/input. Denied Resume must not create a new exec automatically.
- [ ] Leave an actively printing terminal: phone frontend detaches, persistent panes remain.
- [ ] Background for <60 seconds and >60 seconds; confirm resume/detach. Force-stop and reconnect.
- [ ] Run on a 16 KB-page-size ARM64 phone/emulator. ELF/ZIP alignment checks alone do not prove runtime behavior.

Current automated coverage includes real native Ghostty and JNI execution on Linux, Kotlin InputConnection/view tests under Robolectric, loopback QUIC and real PTY tests. Physical Android rendering/IME integration and connectivity require manual validation.
