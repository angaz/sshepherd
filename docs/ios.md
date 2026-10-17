# Native iOS implementation

SSHepherd now includes a native SwiftUI/UIKit iPhone client alongside the existing
Kotlin/Android application. Neither platform uses a WebView. The iOS deployment
target is iOS 18; Xcode 26.3 and Apple Silicon builds have been exercised. This is
an experimental implementation, not an App Store release or full Android parity.

The contribution starts from upstream `master` at `7448d8c`. Android, Rust/JNI,
its namespace, transport, clipboard handling and build workflow are retained.
Only the shared terminal gains an additive Apple entry point, and the pinned
Ghostty download gains macOS-compatible checksum verification. No private
application history or device configuration is imported.

## What is ported

- The existing pinned libghostty-vt parser, terminal modes, query replies,
  grapheme/cell snapshots, key and mouse encoding, via an owned-buffer C ABI.
- A native UIKit cell renderer and composing-text/hardware-keyboard input.
- Saved, editable servers; generated Ed25519 or saved-password authentication;
  explicit host-fingerprint acceptance and changed-key rejection.
- Native controls, confirmed text paste, bounded streaming input/output, PTY
  sizing, no-replay reconnect and background detachment.
- Searchable Agents/Workspaces, client-local selection with acknowledgement,
  and atomic last-server/per-server view restoration.
- The shepherd artwork as an opaque 1024-pixel iOS app icon. iOS supplies the
  rounded mask; this is not a layered Icon Composer/Liquid Glass asset.

## Platform differences

| Area | Existing Android | iOS |
| --- | --- | --- |
| UI | Kotlin Views, Material components, Canvas | SwiftUI navigation, UIKit terminal and input |
| Transport | Existing Rust Herdr Eternal transport | SwiftNIO SSH, an accepted PTY, then `herdr --session default` |
| Connection settings | Existing Android inventory/token model | Independent SSH host/port/user inventory and Keychain credentials |
| Server prerequisites | Existing Eternal setup and in-memory PTY helper | SSH-accessible Herdr; optional explicitly installed phone bridge below |
| Workspace selection | Existing public Herdr API; selection can affect other clients | Optional bridge routes focus on this frontend's endpoint connection only |
| Navigation | Existing Android toolbar and tab controls | Compact Agents/Workspaces top bar, Switch server menu; Tab, Ctrl-C, Clear line, extra keys and keyboard below |
| View restoration | Existing Android behavior unchanged | Remember server and acknowledged phone-local view; changed boot/deleted target falls back to picker |
| Clipboard/files | Existing OSC 52 remote copy and image/text-file transfer | User-confirmed UTF-8 text paste only; no remote OS clipboard writes/reads or file/image upload |
| Native artifacts | Existing Android ABIs and 16 KB ELF alignment | arm64 iPhone, arm64 Simulator and arm64 macOS test slices |

Selection independence does **not** make panes independent: terminal input,
output and size remain shared with other clients of the same pane. The bridge
must not be substituted with a second public focus/API connection. Without a
compatible bridge, ordinary SSH terminal operation is available, but the native
catalog is not. Herdr bindings are server-configurable; do not assume the Android
Ctrl-A shortcuts match a server's prefix.

Not ported: Eternal transport migration, Android attachment/image insertion,
remote clipboard writes, Android IME-specific gestures, or settings/credential
migration between platforms. Neither renderer promises inline graphics, local
scrollback browsing, selection/copy, or complete underline/ligature rendering.

## Build

Requirements: full Xcode with the requested SDK/simulator installed, Zig **0.16.0**,
Python 3, curl and the Swift package dependencies resolved by Xcode/SwiftPM.
Pillow is needed only to regenerate/check the icon. Nix is optional:

```sh
nix-shell scripts/ios-tools.nix
./scripts/build-ios-native.sh
./scripts/build-ios-app.sh
```

Alternatively put Zig 0.16.0 on PATH or set `ZIG_BIN` to its executable. The first
script builds the three distinct slices and generates
`ios/AppCore/Native/SSHepherdTerminal.xcframework`; generated binaries and fetched
dependencies are ignored, not distributed in Git. The second builds, installs,
launches and terminates a simulator app. Override `IOS_SIMULATOR_RUNTIME` and
`IOS_SIMULATOR_DEVICE` to choose an installed simulator; defaults are iOS 26.3 and
iPhone 17 Pro. Intel simulator slices are not currently provided.

For device deployment, first generate the XCFramework, open
`ios/SSHepherd.xcodeproj`, select a connected/unlocked iPhone with Developer Mode,
and choose your own signing team and bundle identifier. Signing is disabled in
the shared project; enable it locally for the app. No team, certificate or
provisioning profile is checked in. The neutral default bundle identifier is
`io.angaz.sshepherd.ios`. Changing it or the Keychain service creates separate
storage; there is no automatic migration from a separately signed development
app. Do not uninstall an existing app or overwrite its configuration to test
this contribution. Simulator and phone keys must be generated/enrolled separately.

## SSH and optional native catalog

The app has no bundled servers. Enter an approved private/mesh endpoint, username
and authentication mode. All resolved addresses must be RFC1918, RFC4193 or
CGNAT; public and loopback destinations are rejected. Supply mesh routing outside
the app. Accept a host key only after independently verifying its fingerprint.
Ed25519 private keys and passwords stay in non-synchronizing,
`WhenUnlockedThisDeviceOnly` Keychain records; JSON contains no credentials or
terminal content. Keyboard-interactive authentication, agent forwarding and SSH
config-file parsing are not implemented.

For client-local browsing, install `scripts/herdr-phone-bridge.py` on the SSH
host through an independently approved process. It needs Python 3, the stock
Herdr executable, its existing client socket, and a private runtime directory.
Use a dedicated device key with an OpenSSH forced command:

```text
command="exec /usr/bin/python3 /absolute/path/herdr-phone-bridge.py --herdr /absolute/path/herdr --socket /absolute/path/herdr-client.sock --runtime-dir /absolute/path/private-runtime",restrict,pty <DEVICE_PUBLIC_KEY>
```

Replace placeholders locally. Keep `restrict,pty`; leave other authorized keys
and running desktop agents untouched. The bridge proxies a stock Herdr frontend
inside a PTY, preserving terminal and binary surface traffic. Bounded private
OSC 777 JSON carries catalog/selection messages; only allowlisted workspace/pane
focus requests are injected on that frontend's existing endpoint connection.
Acknowledgement, revision, boot and attachment-generation guards prevent stale
restore requests and uncertain input. View persistence stores only server UUID,
boot, workspace and pane IDs. Selection or input may resize/write an existing
pane; it must not restart agents or change another client's navigation.

The bridge was exercised against Herdr 0.9.1 endpoint protocol 22 with a 0.9.3
frontend. Its named control messages are versioned, but they are not a guarantee
of compatibility with all Herdr releases. An incompatible/missing catalog is a
visible failure, not permission to mutate shared focus through another API.

## Validation and remaining gates

```sh
./scripts/test-apple-terminal.sh
swift test --package-path ios/SecurityCore
swift test --package-path ios/AppCore
./scripts/test-ios-ssh.sh
./scripts/test-ios-app-ssh.sh
./scripts/test-ios-ui-ssh.sh
python3 scripts/test-herdr-phone-bridge.py --herdr /path/to/test/herdr \
  --scratch-dir /path/to/private/test-runtime
python3 scripts/generate-ios-icon.py --check
```

AppUI is UIKit-dependent and tested using the hosted
`SSHepherdInteractionTests` Xcode scheme, not host macOS `swift test`. The UI SSH
gate creates a disposable simulator and temporary sshd, generates fixture keys,
verifies host trust before authentication, and checks input, resize, reconnect
and remembered-server cold launch. The AppCore SSH gate needs a private interface
(`APP_SSH_FIXTURE_ADDRESS` can select one). Fixture addresses/keys in tests are
synthetic or generated at runtime, not enrolled device identities. Use only
isolated Herdr sessions for bridge tests; never restart production to satisfy a
gate. Standard test-script temporary-directory behavior can be redirected with
`TMPDIR`.

Earlier development exercised the native terminal/navigation/icon on a physical
iPhone as well as simulator/OpenSSH fixtures. That does not validate this new
bundle/signing identity, every network transition or every Herdr version. A
password-enabled server, new device signing, lock/background/network transitions,
and release/distribution acceptance still require explicit manual checks.

Before publication, review staged files and run a secret scan. Do not include
server/trust/navigation JSON, exported keys, local signing settings, screenshots,
logs, build products or downloaded dependencies. Local native build paths are
remapped using upstream's existing `native-path-flags.sh`; this is not a license
to publish development binaries without a separate artifact review.
