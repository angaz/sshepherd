# SSHepherd — native Android

A **native Android** client for your Herdr terminals over QUIC. Kotlin Android Views, an Android Canvas terminal renderer and the **native libghostty-vt** engine. **No WebView, HTML/JavaScript UI, WASM, Flutter or browser runtime.**

## Install

APK: `android/app/build/outputs/apk/debug/app-debug.apk`

```fish
adb install -r android/app/build/outputs/apk/debug/app-debug.apk
```

1. The device must resolve the configured server hostname and reach UDP **7443**. Use allowed address ranges.
2. Open **Connection settings** and paste the shared token from a trusted server. It is encrypted using Android Keystore. No token is bundled or read from your machine during development.
3. Confirm the server trust notice, then tap a server. The sample server inventory includes offline entries.
4. Herdr opens its existing `default` session. **Prev tab / Next tab / Workspaces / Zoom** send the `Ctrl+A` prefix; configure matching server bindings. Taps/drags send mouse events to Herdr and its TUIs.
5. **Keyboard** opens the normal Android IME with suggestions/autocorrection and swipe typing permitted. Automatic capitalization stays off, and the app requests no personalized learning from terminal input. The horizontally scrollable accessory row provides Ctrl, Ctrl+C/D, Esc, Tab, Enter, arrows, Home/End, PgUp/PgDn, Prefix and confirmed Paste. Physical keyboards use Ghostty's key encoder, including terminal/application cursor modes and layout-generated AltGr text.

Returning to Servers detaches the phone's Herdr frontend, not the persistent server or panes. Network interruptions resume the same Eternal exec with sequence/ACK replay. Input is paused while reconnecting. Backgrounding for over 60 seconds detaches.

## Implementation

| Layer | Technology |
| --- | --- |
| App UI and lifecycle | Kotlin, standard Android Activity and Views |
| Terminal drawing | Custom native `TerminalView`, Android Canvas/Paint and system font fallback |
| Terminal engine | Native **libghostty-vt**, written in Zig, statically linked into an Android `.so` |
| Terminal binding | Small C++ JNI wrapper; copies bounded cell/grapheme snapshots to Kotlin |
| Keyboard | Real Android `InputConnection`; local composition until commit; Ghostty hardware-key encoding |
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

Eternal executes commands over pipes without a PTY. The bundled helper runs **in memory remotely**, creates a PTY and launches the installed Herdr frontend. Requires `python3` and `herdr` on Eternal's PATH; configure the server to provide both. No files, daemon, new listener or configuration changes are installed remotely.

## Security

QUIC encrypts traffic, but does not verify server certificates. **Authenticate server identity independently**, using trusted endpoints and DNS rather than a CA-validated certificate. The app requires explicit consent and restricts destinations to the six compiled-in hostnames and ULA IPv6. ULA filtering is not certificate pinning. There is no public WebSocket fallback, agent forwarding or remote update mechanism.

Token material never leaves native code/UI except in the authenticated transport handshake. Terminal content cannot execute app code. Remote clipboard read/write effects are not registered; Paste requires a user action and confirmation. Screenshots and app-switcher previews are allowed; be mindful that they can expose terminal content. The build script produces a debug-signed sideload APK.

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

The script verifies/downloads pinned Ghostty source, runs host engine/JNI/Rust/Python tests, builds both native libraries, runs Kotlin/Robolectric tests and Android lint, then assembles the APK. Gradle refuses a package missing either native library or containing stale HTML/JS/WASM assets. A native-only CI workflow is included.

## Validation and limits

[Validation evidence](docs/validation.md) · [Device checklist](docs/device-checklist.md) · [Research/compatibility](docs/research.md)

Automated tests exercise the native engine/JNI, loopback transport/PTY and Android input/UI logic. They do not replace physical-device checks. Tests use fixtures rather than deployment credentials or existing remote sessions.

This first native version targets Android 8+. It uses the fixed inventory and `default` session; initially shows the existing Herdr selection rather than changing your desktop's selected tab. Native Canvas rendering does not currently implement inline images, ligatures, local selection/copy, or a local scrollback browser; Herdr's own copy-mode/scroll controls remain available. Underline variants are rendered as a single underline. Real OEM input behavior and 16 KB-device execution are still on the device checklist.
