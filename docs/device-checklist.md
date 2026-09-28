# Native Android acceptance checklist

Automated native-engine/JNI and Robolectric tests do not replace on-device checks.

- [ ] Install the **0.2.1-native** APK over the old debug build. Confirm native controls and no WebView/browser dependency.
- [ ] Launch offline: the empty host list appears. Offline connection failure leaves the host visible and retryable.
- [ ] Save shared token, relaunch and connect; Forget token makes the next connection request credentials. Confirm server trust notice.
- [ ] Connect through mesh IPv6 UDP 7443 and verify existing `default` Herdr state.
- [ ] Tap and drag tab/pane controls and mouse-aware TUIs. Exactly one press/release pair, correctly aligned to cells; no stuck mouse on cancellation.
- [ ] Test Gboard and the preferred IME: suggestions, swipe typing, committed text, composition, Unicode/emoji, backspace at an empty local editor, Enter while composing, cancellation and paste. Commands must not be automatically capitalized.
- [ ] Take a screenshot and inspect the app-switcher preview: terminal/UI content should be visible, not blank.
- [ ] Test physical keyboard: Ctrl+C, Alt terminal shortcuts, AltGr/layout characters, dead keys, Shift+Tab, arrows in normal/application modes and Kitty-aware apps.
- [ ] Show/hide IME and rotate: terminal fits between native navigation/accessory rows; remote geometry updates even after input backpressure.
- [ ] Verify bold/italic/underline, RGB/palette colours, combining marks, CJK/emoji wide cells, cursor, alternate screen, full-screen TUI repaint.
- [ ] Switch tabs/workspaces and zoom with ctrl+a-based controls; pending composition commits before navigation.
- [ ] Temporarily disable VPN during output; restore it and confirm replay without duplicate output/input. Denied Resume must not create a new exec automatically.
- [ ] Leave an actively printing terminal: phone frontend detaches, persistent panes remain.
- [ ] Background for <60 seconds and >60 seconds; confirm resume/detach. Force-stop and reconnect.
- [ ] Run on a 16 KB-page-size ARM64 phone/emulator. ELF/ZIP alignment checks alone do not prove runtime behavior.

Current automated coverage includes real native Ghostty and JNI execution on Linux, Kotlin InputConnection/view tests under Robolectric, loopback QUIC and real PTY tests. Physical Android rendering/IME integration and connectivity remain unverified.
