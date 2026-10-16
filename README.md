# SSHepherd — native Android

A **native Android** client for Herdr terminals. Kotlin Android Views with Material 3 components, an Android Canvas terminal renderer and the **native libghostty-vt** engine. **No WebView, HTML/JavaScript UI, WASM, Flutter or browser runtime.**

## Install

APK: `android/app/build/outputs/apk/debug/app-debug.apk`

```fish
adb install -r android/app/build/outputs/apk/debug/app-debug.apk
```

1. The device must resolve the configured hostname (or use a literal IP) and reach UDP **7443**. ULA IPv6, private IPv4 and CGNAT addresses are supported.
2. Open **Connection settings** and paste the shared token from your trusted server. It is encrypted using Android Keystore. No token is bundled or read from your machine during development.
3. Confirm the server trust notice, then tap a server. Use **+** to add a friendly name and hostname/IP, or a card's **pencil** to edit/delete it. Addresses appear on the right; hosts remain listed when offline. Changes persist on the phone, including an empty list. All hosts use the shared token and port 7443. DNS errors/timeouts retry automatically up to three attempts (8 seconds each, with 1/2-second retry delays); literal IPs bypass DNS.
4. Herdr opens its existing `default` session. **Prev tab / Next tab / Zoom** send the `Ctrl+A` prefix; configure the server to use matching bindings. **Workspaces** opens a full-screen native, scrollable list of workspaces and recognized agents, with status and tap-to-switch. Opening it hides the keyboard; the toolbar arrow or Android Back returns to the connected terminal without reopening the keyboard. Refresh fetches current metadata without changing focus; selecting a row uses Herdr's public API and also switches other attached Herdr clients. Taps/drags send mouse events to Herdr and its TUIs.
5. **Keyboard** opens the normal Android IME with suggestions/autocorrection and swipe typing permitted. Automatic capitalization stays off, and the app requests no personalized learning from terminal input. The compact, two-row bottom bar keeps Esc, Tab, Ctrl, Ctrl+C, all four arrows, Home/End and PgUp/PgDn visible. Ctrl lights up when latched and resets after the next key. Its expand icon reveals Enter, Backspace/Delete, Ctrl+D, Prefix, Paste and Attach; the keyboard icon stays at the bottom right. On very short windows the expanded grid can scroll vertically, never sideways. Tab arrows and the native **Workspaces & agents** list are directly in the top app bar; Zoom is in its overflow menu. Gboard-style space-bar cursor gestures move the remote caret within the app's retained phone-typed text (not arbitrary terminal history). Physical keyboards use Ghostty's key encoder, including terminal/application cursor modes and layout-generated AltGr text.

**New workspace:** in **Workspaces & agents**, tap **+** to open the native searchable project picker. Like the nix-configs Herdr Ctrl+K helper, it lists Git projects/worktrees under `~/Documents` (up to two directory levels) and **Empty (~)**. Tap a project to create and focus a workspace on the connected server. This also switches other attached clients. Creation is never automatically retried after an uncertain response; reconnect and inspect the workspace list first.

**Terminal viewport:** the recognized two-row Herdr mobile header (workspace/status/“switch”) is hidden locally, leaving the pane at full height with correctly offset mouse input. This does not change shared Herdr configuration or desktop clients. Recognized-agent counts (for example, “1 working · 13 idle”) appear in the native connection-status label and refresh about every two seconds while the terminal is foregrounded. If the metadata API is unavailable, the terminal remains usable without counts. Other/unrecognized Herdr layouts are not cropped. If a legacy overlay replaces a detected mobile header, all its rows are fitted into the viewport, with matching mouse coordinates.

**Links:** tap a visible `http://`, `https://` or `www.` URL, or a received OSC 8 web hyperlink, to open it in the phone's browser/URL handler. Soft-wrapped URLs are joined; surrounding prose punctuation is excluded. Link taps are handled locally without clicking the remote TUI. Drags, long presses and ordinary non-link touches retain remote mouse input. Only HTTP(S) destinations are launched, and nothing opens automatically from terminal output.

**Hidden/labeled links with mouse capture:** Herdr 0.9.4 omits OSC 8 destinations from its rendered terminal stream when mouse capture is enabled. SSHepherd now asks the existing `pane.link.activate` API for the tapped destination instead; no Herdr patch or shared configuration change is needed. This fallback currently requires the recognized mobile header and a single borderless pane with matching geometry (split/other layouts retain normal mouse taps). It verifies the displayed row, pane focus, geometry, scroll offset and content revision before activation. Ordinary text taps are briefly deferred for lookup and forwarded if no link exists; drags and long presses still go straight to mouse input. Busy/stale lookups show a retry notice. An unavailable API falls back to a normal mouse tap. Herdr may invoke a configured link plugin; if it reports `handled`, the phone does not open the link again. Only HTTP(S) URLs are opened locally. Install the new APK and disconnect/reconnect so the remote in-memory bridge is replaced.

**Scrollback scratchpad:** open **Scrollback scratchpad** from the terminal toolbar overflow menu for a native, editable local snapshot of the focused pane. Long-press to select/copy using normal Android handles and use **Keyboard** to edit. Edits are never sent to the terminal; closing discards them (with confirmation if edited). The snapshot requests the last 10,000 unwrapped lines, capped locally at 256 KiB; the pinned Herdr API currently limits it to 1,000 lines. Alternate-screen TUIs may only expose their current screen. Reads are passive and do not scroll other clients. There is no automatic refresh or disk persistence. The local copy survives automatic network/background detach while the Activity remains alive; force-stop or process destruction can discard it.

**Remote copy:** terminal clipboard writes (OSC 52) put plain text on the phone's clipboard while the connected terminal window is active. UTF-8 text is capped at 60 KB; malformed/oversized writes, selection-only writes and clipboard-clear requests are ignored. Any program on the trusted remote host can replace the clipboard while that window is active. Remote clipboard reads are disabled, so a terminal query cannot retrieve the phone's clipboard.

**Images and text files:** use **Attach** to choose a file, **Paste** for a clipboard file/image, or the keyboard's image-insertion action. PNG/JPEG/GIF/WebP/BMP images (up to 16 MiB) are transferred through Herdr's native image-paste mechanism; Herdr saves a remote temporary file and pastes its path into the current pane. UTF-8 text files (up to 60 KB) paste their contents after confirmation, not a filename. Unsupported binary/control-containing files are rejected. Input pauses during image transfer; the status indicates queuing, not a server acknowledgement. Upload staging is capped at 64 MiB per connection; reconnect to reset it.

Returning to Servers detaches the phone's Herdr frontend, not the persistent server or panes. Network interruptions resume the same Eternal exec with sequence/ACK replay. Input is paused while reconnecting. Backgrounding for over 60 seconds detaches.

## Implementation

| Layer | Technology |
| --- | --- |
| App UI and lifecycle | Kotlin, AppCompatActivity, Material 3 toolbar/cards/buttons/dialogs and native Views |
| Terminal drawing | Custom native `TerminalView`, Android Canvas/Paint and system font fallback |
| Terminal engine | Native **libghostty-vt**, written in Zig, statically linked into an Android `.so` |
| Terminal binding | Small C++ JNI wrapper; copies bounded cell/grapheme snapshots to Kotlin |
| Keyboard | Real Android `InputConnection`; live composing-text/candidate replacement; Ghostty hardware-key encoding |
| Mouse | Android `MotionEvent` → Ghostty's native mouse encoder |
| Transport | Rust, Tokio, Quinn, rustls, Serde/postcard, JNI |
| Credentials | Android Keystore, AES-GCM, backup/device-transfer exclusions |
| Remote PTY | In-memory Python 3 standard-library helper |

`libsshepherd_terminal.so` contains Ghostty and the C++ wrapper. `libsshepherd.so` contains the Rust transport. Both are built for ARM64 and x86_64 with 16 KB ELF alignment. Kotlin renders colours, attributes, Unicode grapheme clusters, wide cells and cursor state supplied by Ghostty; it does **not** implement another ANSI parser. Ghostty also generates terminal query replies.

```text
Native Kotlin UI / Canvas / InputConnection
        ↕ JNI
Native libghostty-vt ← terminal bytes → Rust Eternal client
                                         ↕ QUIC
                                  Existing Eternal server
                                         ↕ Python PTY
                                  herdr --session default
                                         ↕
                                  Persistent Herdr server
```

Eternal executes commands over pipes without a PTY. The bundled helper runs **in memory remotely**, creates a PTY and launches the installed Herdr frontend. Requires `python3` and `herdr` on Eternal's PATH; configure the server to provide both. No daemon, new listener or configuration changes are installed remotely. Workspace metadata is read through Herdr's existing default-session Unix socket; only allowlisted metadata and explicitly requested bounded scrollback snapshots are forwarded separately from terminal bytes. A missing/incompatible API displays an error without opening the terminal sidebar. Switching waits for queued PTY input to drain and pauses new terminal input until confirmation, even if the list is closed. If a switch cannot be confirmed, input stays paused; return to Servers and reconnect rather than typing into an uncertain target. Image transfer creates private temporary staging files that are removed on normal detach; Herdr manages its own final clipboard-image files.

## Security

QUIC encrypts traffic, but does not verify server certificates. **Authenticate server identity independently**, using trusted endpoints and DNS rather than a CA-validated certificate. The app requires explicit consent and restricts destinations to ULA IPv6, RFC1918 private IPv4 or CGNAT IPv4 (100.64.0.0/10). Public, loopback and link-local destinations are rejected before sending the token. IPv6 is preferred when a hostname has multiple permitted answers. An allowed address alone does not authenticate a machine; only add endpoints you trust. This filtering is not certificate pinning. There is no public WebSocket fallback, agent forwarding or remote update mechanism.

Token material never leaves native code/UI except in the authenticated transport handshake. Terminal content cannot execute app code. Remote clipboard text writes are supported only for the active terminal window; remote clipboard reads remain disabled. Paste into the remote terminal still requires a user action and confirmation. Screenshots and app-switcher previews are allowed; be mindful that they can expose terminal content. The build script produces a debug-signed sideload APK. Existing installations may need to reconfirm server trust after a settings-key update; saved hosts and tokens are retained.

## Build

Requires **Zig 0.16.0**, **Rust 1.95.0**, JDK 17/21, a host C++ compiler, Python 3, curl, Android SDK/build-tools 35 and NDK **28.0.13004108**. No Node/npm installation is needed.

On NixOS:

```fish
nix develop
rustup toolchain install 1.95.0 --profile minimal
rustup target add --toolchain 1.95.0 aarch64-linux-android x86_64-linux-android
./scripts/build-android.sh
```

The pinned Nix shell supplies Zig, patched Android tools, JDK, host C++ compiler, rustup and cargo-ndk; it accepts the Android SDK license via nixpkgs configuration. On other Linux hosts, install the prerequisites and:

```fish
cargo install cargo-ndk --version 4.1.2 --locked
set -gx ANDROID_HOME $HOME/Android/Sdk
set -gx ANDROID_NDK_HOME $ANDROID_HOME/ndk/28.0.13004108
sdkmanager 'platforms;android-35' 'build-tools;35.0.0' 'ndk;28.0.13004108'
./scripts/build-android.sh
```

The script verifies/downloads pinned Ghostty source, runs host engine/JNI/Rust/Python tests, builds both native libraries, runs Kotlin/Robolectric tests and Android lint, then assembles the APK. Gradle refuses a package missing either native library or containing stale HTML/JS/WASM assets. A native-only CI workflow is included. Native compiler paths are remapped and generated artifacts are checked for local paths before distribution.

## Validation and limits

[Validation evidence](docs/validation.md) · [Device checklist](docs/device-checklist.md) · [Research/compatibility](docs/research.md)

Automated tests exercise the **real native Ghostty library and JNI**, plus real loopback QUIC/PTY integration and Android input/view logic under Robolectric. They are not a substitute for physical-phone tests. The image path also has an opt-in real-Herdr integration test in an isolated local session (`SSHEPHERD_TEST_HERDR=/path/to/herdr python3 -m unittest discover -s tests -v`). Automated tests use fixtures rather than deployment credentials or live remote sessions.

This first native version targets Android 8+. It uses a saved, editable inventory and the `default` session; initially shows the existing Herdr selection rather than changing your desktop's selected tab. Native Canvas rendering does not currently implement inline images, ligatures, direct Canvas selection/copy; use the native scrollback scratchpad or Herdr's own copy-mode/scroll controls instead. Underline variants are rendered as a single underline. Real OEM input behavior and 16 KB-device execution are still on the device checklist.
