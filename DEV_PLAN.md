# Dev Plan: M1 — a TestFlight build of term-app that connects over SSH with saved hosts and keys, and survives backgrounding via reconnect + tmux

## Overview
Build the M1 milestone from `docs/SPEC.md`: an iOS 18 SwiftUI app target in a committed Xcode project,
plus three local Swift packages: `SSHKit` (libssh2 1.11+ on OpenSSL 3, as an XCFramework), `Store`
(SwiftData + Keychain) and `TermUI` (SwiftTerm). The seams are the `Session` protocol in SSHKit and
the `TerminalIO` protocol in TermUI. The app bridges the two, so TermUI never imports SSHKit and the
M4 `MoshSession` drops in without UI changes. After T1, the work splits into an SSH lane
(T2) and a storage lane (T3). The UI tasks (T4–T8) then fan out over those, and resilience and sync
(T9–T10) follow, then the TestFlight gate (T11). `DOKit`, SFTP, port forwarding and Mosh are deliberately not
started (M2–M4).

## Design principles
- Swift 6 language mode with strict concurrency in every target. No `@unchecked Sendable` without a comment saying why.
- Each SSH connection is an `actor`. libssh2 is only called from that actor's serial executor, in non-blocking mode.
- Secrets (private keys, passwords, the host-key store) live only in Keychain via `KeychainStore`. SwiftData models hold IDs, never secret bytes.
- SwiftData models must stay CloudKit-compatible: every attribute optional or defaulted, relationships optional, no `@Attribute(.unique)`, no `.deny` delete rules.
- No third-party SDKs other than SwiftTerm and the vendored libssh2/OpenSSL. No analytics, no logging of session content.
- Tests run through `scripts/test.sh <scheme>`. Integration tests that need a real server read `TERMAPP_TEST_HOST`, `TERMAPP_TEST_USER`, `TERMAPP_TEST_PASSWORD`, `TERMAPP_TEST_KEY_PATH` and skip with `XCTSkip` when they are unset. `xcodebuild` does not pass shell variables into the simulator, so `scripts/test.sh` re-exports each as `TEST_RUNNER_TERMAPP_TEST_*`; set the plain names in the shell and run through the script.
- Wiring files: `App/TermApp.swift` and `App/RootView.swift` are created by T1. T3, T5, T7, T8, T9 and T10 may each add only their own wiring lines there, each marked `// wiring: Tn`. They touch nothing else in those files. Some of those tasks can run in parallel (for example T8 or T9 alongside T10 on `App/TermApp.swift`, and T8 and T10 on `App/RootView.swift`); any merge conflict on wiring lines is resolved by the lead at merge. The other shared-file exceptions are the after-merge edits declared in the ownership map (T4's `readAll`, T8's hand-off lines, T9's lines in T2's and T7's files) and T12's owner-approved test target in `TermApp.xcodeproj`.
- Commit messages are one plain line with no trailers.

## Task T1: Project scaffold and libssh2 XCFramework
### Tree org map
```
TermApp.xcodeproj/                            [NEW]
Config/Info.plist                             [NEW]
Config/TermApp.entitlements                   [NEW]
.gitignore                                    [NEW]
App/TermApp.swift                             [NEW]  (wiring file)
App/RootView.swift                            [NEW]  (wiring file)
App/Resources/Assets.xcassets/                [NEW]  (with a placeholder AppIcon)
App/Resources/PrivacyInfo.xcprivacy           [NEW]
scripts/build-libssh2.sh                      [NEW]
scripts/test.sh                               [NEW]
Packages/SSHKit/Package.swift                 [NEW]
Packages/SSHKit/Sources/SSHKit/SSHKit.swift   [NEW]
Packages/SSHKit/Tests/SSHKitTests/VersionTests.swift [NEW]
Packages/Store/Package.swift                  [NEW]
Packages/Store/Sources/Store/Store.swift      [NEW]
Packages/Store/Tests/StoreTests/PlaceholderTests.swift [NEW]
Packages/TermUI/Package.swift                 [NEW]
Packages/TermUI/Sources/TermUI/TermUI.swift   [NEW]
Packages/TermUI/Tests/TermUITests/PlaceholderTests.swift [NEW]
```
### List of changes
1. `scripts/build-libssh2.sh`: download pinned, checksum-verified releases of OpenSSL 3.5.x (the current LTS; 3.0 is end of life) and libssh2 1.11.x. Build static libraries for `ios-arm64` and `ios-arm64_x86_64-simulator` with zlib compression disabled, merge `libssh2.a`, `libssl.a` and `libcrypto.a` into one archive per platform with `libtool -static`, and package them as `Packages/SSHKit/Vendor/CLibSSH2.xcframework` with a module map exposing `libssh2.h` and `libssh2_sftp.h`. That `Vendor/` folder is gitignored.
2. `Packages/SSHKit/Package.swift`: iOS 18, Swift 6, a `binaryTarget` `CLibSSH2` at `Vendor/CLibSSH2.xcframework` (SwiftPM requires the path to be inside the package), and the `SSHKit` target depending on it. `SSHKit.swift` exposes `SSHKit.libraryVersion() -> String` wrapping `libssh2_version(0)`.
3. `Packages/Store/Package.swift` and `Packages/TermUI/Package.swift`: iOS 18, Swift 6. TermUI depends on SwiftTerm (pinned to an exact release). Store's test target depends on SSHKit (for T4's login test); the Store library itself does not. Each has a one-line placeholder source file and a placeholder test file, so the test targets resolve before later tasks add tests.
4. `TermApp.xcodeproj`: app target `TermApp` (bundle id `com.peculiarengineer.termapp`), iOS 18, depending on the three local packages. The `App/` folder is an Xcode 16 synchronized folder, so files later tasks add under `App/` are included without editing the project file. Info.plist and entitlements live outside it in `Config/`, so they are not copied as resources. `Config/Info.plist`: `NSLocalNetworkUsageDescription`, `ITSAppUsesNonExemptEncryption` = `true`, `UIApplicationSupportsMultipleScenes` = `true`, `UIBackgroundModes` = `remote-notification` (CloudKit push sync), `UILaunchScreen` (empty dictionary), and all four orientations for iPad plus portrait and both landscapes for iPhone (iPad multitasking requires all four). Orientation keys: `UISupportedInterfaceOrientations` and `UISupportedInterfaceOrientations~ipad`. The plist sets `CFBundleShortVersionString` = `$(MARKETING_VERSION)` and `CFBundleVersion` = `$(CURRENT_PROJECT_VERSION)`. Build settings: `INFOPLIST_FILE` = `Config/Info.plist`, `ASSETCATALOG_COMPILER_APPICON_NAME` = `AppIcon`, `MARKETING_VERSION` = `1.0`, `CURRENT_PROJECT_VERSION` = `1` (later builds get their number from Xcode's "Manage version and build number" at distribution, so no committed edit), automatic signing with `DEVELOPMENT_TEAM` set to the team ID the owner supplies before T1 starts. `Config/TermApp.entitlements`: iCloud with CloudKit container `iCloud.com.peculiarengineer.termapp`, `aps-environment` = `development`, and a `keychain-access-groups` entry.
5. `App/Resources/PrivacyInfo.xcprivacy`: `NSPrivacyTracking` = false, no tracking domains, no collected data types, and the required-reason API `NSPrivacyAccessedAPICategoryUserDefaults` with reason `CA92.1`. Add any further reasons that SwiftData or the pinned SwiftTerm release need (check whether SwiftTerm ships its own manifest), and after linking run `nm -u` on the app binary for required-reason symbols from the static OpenSSL and libssh2 (the `stat` family, `mach_absolute_time`, disk-space APIs) and add their categories and reasons. `Assets.xcassets` gets an `AppIcon` set with a single 1024 px placeholder icon (naming and the real icon are deferred).
6. `App/TermApp.swift`: an `@main` app with a `WindowGroup { RootView() }`. `App/RootView.swift`: a placeholder `NavigationStack` with a title.
7. `scripts/test.sh <scheme>`: re-export `TERMAPP_TEST_*` as `TEST_RUNNER_TERMAPP_TEST_*` and run `xcodebuild test` for the scheme on the first available iPhone simulator.
8. `.gitignore`: `Packages/SSHKit/Vendor/`, `DerivedData/`, `.DS_Store`, `xcuserdata/`, `.plan-gate/`.
### Reason for changes
Every other task builds on this layout and the vendored C library. The synchronized `App/` folder means parallel tasks never edit the project file, so it does not conflict. All Info.plist keys and entitlements are set here, once.
### Done when
- `scripts/build-libssh2.sh` exits 0 and `Packages/SSHKit/Vendor/CLibSSH2.xcframework/Info.plist` lists both `ios-arm64` and `ios-arm64_x86_64-simulator`.
- `xcodebuild build -scheme TermApp -destination 'generic/platform=iOS Simulator'` succeeds.
- `plutil -lint App/Resources/PrivacyInfo.xcprivacy Config/Info.plist` passes, `plutil -extract UILaunchScreen raw Config/Info.plist` succeeds, `test -f App/Resources/Assets.xcassets/AppIcon.appiconset/Contents.json` succeeds, and `xcodebuild -showBuildSettings -scheme TermApp` shows a non-empty `DEVELOPMENT_TEAM`, `MARKETING_VERSION = 1.0` and `CURRENT_PROJECT_VERSION = 1`.
- `scripts/test.sh SSHKit` passes, and `VersionTests` asserts that `SSHKit.libraryVersion()` starts with `1.11` or later.
### Depends on
none

## Task T2: SSHKit connection
### Tree org map
```
Packages/SSHKit/Sources/SSHKit/
├── Session.swift              [NEW]
├── SSHConnection.swift        [NEW]
├── SSHAuth.swift              [NEW]
├── HostKey.swift              [NEW]
├── SSHError.swift             [NEW]
└── SocketPoller.swift         [NEW]
Packages/SSHKit/Tests/SSHKitTests/
└── SSHConnectionIntegrationTests.swift [NEW]
```
### List of changes
1. `Session` protocol: `connect(verifyHostKey: @Sendable (HostKey) async -> HostKeyDecision) async throws`, `write(_ data: Data) async throws`, `resize(cols: Int, rows: Int) async throws`, `output: AsyncStream<Data>`, `state: AsyncStream<SessionState>`, `close() async`. `SessionState`: `.connecting`, `.awaitingHostKeyDecision(HostKey)`, `.authenticating`, `.connected`, `.disconnected(SSHError?)`.
2. `SSHConnection` actor implements `Session`. It opens a TCP socket, runs `libssh2_session_handshake` in non-blocking mode, and drives libssh2 calls from `SocketPoller` readiness events.
3. `HostKey`: the key type and the SHA-256 fingerprint from `libssh2_hostkey_hash(..., LIBSSH2_HOSTKEY_HASH_SHA256)`, base64-formatted like OpenSSH. The connection pauses after the handshake until the caller supplies a `HostKeyDecision` (`.trust`, `.reject`) via the `verifyHostKey` closure passed to `connect(verifyHostKey:)`.
4. `SSHAuth`: `.password(String)`, `.privateKey(pem: Data, passphrase: String?)` (via `libssh2_userauth_publickey_frommemory`), `.keyboardInteractive(handler: (Prompt) async -> [String])`.
5. After auth, request a PTY (`xterm-256color`) and a shell, and stream channel output to `output`. `resize` calls `libssh2_channel_request_pty_size`.
6. Integration tests: password login, key login, `echo ok` round trip, and resize. All skip when the `TERMAPP_TEST_*` env vars are unset.
7. `close()`, a cancelled connect and every error path free the channel, session and socket, driving libssh2's close and free calls through EAGAIN with a bounded wait. No cooperative-pool thread blocks (including the keyboard-interactive callback), and empty key data fails with `authenticationFailed` instead of crashing.
### Reason for changes
This is the core protocol seam from the spec. TermUI, reconnect and later Mosh all depend on `Session`, never on libssh2.
### Done when
- With the `TERMAPP_TEST_*` vars pointing at a do-lab droplet, `scripts/test.sh SSHKit` passes `SSHConnectionIntegrationTests` (password login, key login, `echo ok` output received, resize succeeds).
- With the vars unset, the same command passes and reports the integration tests as skipped.
### Depends on
T1

## Task T3: Store — hosts and Keychain
### Tree org map
```
Packages/Store/Sources/Store/
├── Model/Host.swift                  [NEW]
├── Keychain/KeychainStore.swift      [NEW]
├── Keychain/KeychainService.swift    [NEW]
└── Keychain/KnownHostsStore.swift    [NEW]
Packages/Store/Tests/StoreTests/
├── HostPersistenceTests.swift        [NEW]
├── KeychainStoreTests.swift          [NEW]
└── KnownHostsStoreTests.swift        [NEW]
App/AppContainer.swift                [NEW]
App/TermApp.swift                     (wiring line only)
```
### List of changes
1. `@Model Host`: `id: UUID = UUID()`, `copyID: UUID = UUID()` (new per insert, never changed; the dedupe tie-break), `label = ""`, `hostname = ""`, `port = 22`, `username = ""`, `authMethod = "password"` (raw string: password, key, keyboardInteractive), `keyID: UUID?`, `tmuxCommand: String?`, `tags: [String] = []`, `source = "manual"`, `createdAt = Date.now`, `updatedAt = Date.now`. All CloudKit-compatible per the design principles. `Host.touch()` sets `updatedAt = .now`; every code path that edits a host calls it before saving.
2. `KeychainStore`: save, read and delete generic-password items keyed by `(service, account)`, with `kSecAttrAccessibleAfterFirstUnlock`. A `synchronizable: Bool` parameter sets `kSecAttrSynchronizable`. Every search, update and delete uses `kSecAttrSynchronizableAny` (not valid in `SecItemAdd`). Unhosted package tests can fail synchronizable items with `errSecMissingEntitlement` (-34018); those cases `XCTSkip` on that status, and T10's two-device check covers the sync path. `setSynchronizable(x, service:account:)` deletes only the item whose `kSecAttrSynchronizable` is `!x` (not `Any`) and re-adds it with `x`. For `x = true`, an `errSecDuplicateItem` on the add means a synced copy already arrived from another device: it keeps the synced item and drops the local one. For `x = false`, a duplicate means a local item already exists: it keeps that one, and the synced item stays deleted. When a read finds both a synced and a local item for one `(service, account)`, it returns the synced one. Service names are public constants in `Keychain/KeychainService.swift`: `knownHosts = "termapp.knownhosts"` (account `host:port`) and `hostPassword = "termapp.hostpassword"` (account = host `id`). T4 defines its own key service names in `Keys/`.
3. `KnownHostsStore` (built on `KeychainStore`): `fingerprint(host:port:) -> String?`, `trust(host:port:fingerprint:synchronizable:)`, `forget(host:port:)`. Callers pass `AppContainer.syncEnabledAtLaunch` as `synchronizable`, so fingerprints trusted while host sync is on sync. If the synced and a local fingerprint differ, the synced one is used, and a server that presents the other key gets the normal mismatch screen.
4. `App/AppContainer.swift`: builds the `ModelContainer` for `Host`. It reads `UserDefaults` key `sync.enabled` (default `false`) once at launch, exposes it as `static let syncEnabledAtLaunch: Bool` so Keychain callers match the container until the next launch, and sets `cloudKitDatabase` to `.private("iCloud.com.peculiarengineer.termapp")` when it is on, `.none` when it is off. One wiring line in `TermApp` attaches it with `.modelContainer(...)`.
### Reason for changes
The storage lane runs in parallel with SSHKit. Putting the CloudKit switch in the container now means T10 only flips a setting and adds deduplication.
### Done when
- `scripts/test.sh Store` passes: hosts persist across a re-created container (on-disk store in a temp dir); `touch()` moves `updatedAt` forward and leaves `copyID` unchanged; two inserted hosts get different `copyID`s; Keychain save/read/delete and synchronizable re-add round-trip; `KnownHostsStore` trust/lookup/forget round-trip.
- `xcodebuild build -scheme TermApp -destination 'generic/platform=iOS Simulator'` succeeds with `AppContainer` compiled in.
### Depends on
T1

## Task T4: Key management
### Tree org map
```
Packages/Store/Sources/Store/Keys/
├── StoredKey.swift          [NEW]
├── KeyGenerator.swift       [NEW]
├── OpenSSHKeyFormat.swift   [NEW]
└── KeyImporter.swift        [NEW]
Packages/Store/Tests/StoreTests/
├── OpenSSHKeyFormatTests.swift  [NEW]
├── KeyImporterTests.swift       [NEW]
├── KeyGeneratorLoginTests.swift [NEW]
└── Fixtures/                    [NEW]
Packages/Store/Sources/Store/Keychain/KeychainStore.swift  (adds readAll(service:) only)
App/Keys/
├── KeyListView.swift        [NEW]
├── KeyGenerateView.swift    [NEW]
└── KeyImportView.swift      [NEW]
```
### List of changes
1. `StoredKey`: id, name, type (ed25519, ecdsa, rsa), public key line, `isEncrypted`, `syncsViaICloud`. Metadata in Keychain next to the private key: one metadata item per key with the same sync flag as the private key (flipped together), so a synced key is listed on every device. The list is built by enumerating that service, via a new `KeychainStore.readAll(service:) -> [(account: String, data: Data, synchronizable: Bool)]` (`kSecMatchLimitAll` + `kSecAttrSynchronizableAny`).
2. `KeyGenerator`: Ed25519 via CryptoKit `Curve25519.Signing`. `OpenSSHKeyFormat` writes the unencrypted `openssh-key-v1` private key and the `ssh-ed25519 AAAA… comment` public line. Its random check integer is injectable, so tests get deterministic output.
3. `KeyImporter`: accepts `openssh-key-v1` and PEM (`-----BEGIN RSA/EC PRIVATE KEY-----`) text. It detects encryption and stores encrypted keys as-is, with the passphrase optionally saved in Keychain. A saved passphrase carries the key's sync flag and is flipped with it. Decryption is left to libssh2 at auth time.
4. Views: list keys; generate; import by paste or Files picker; copy the public key; toggle "Sync via iCloud Keychain" per key (calls `KeychainStore.setSynchronizable` on the key, its metadata and any saved passphrase). The toggle starts off for every generated or imported key, and is independent of the app's "iCloud sync" setting. Turning it off first confirms "This removes the key from your other devices. It stays on this one.", because making a synced Keychain item local deletes it everywhere else.
### Reason for changes
A host's key auth needs stored keys. Leaving decryption to libssh2 avoids implementing bcrypt-pbkdf.
### Done when
- `scripts/test.sh Store` passes `OpenSSHKeyFormatTests` (a generated key's private-key output parses back to the same public key; for a fixed seed and check integer the output equals the checked-in `Fixtures/ed25519-fixed.key`) and `KeyImporterTests` (fixtures for Ed25519, ECDSA, RSA PEM and a passphrase-protected key are classified correctly).
- With `TERMAPP_TEST_*` set, `KeyGeneratorLoginTests` (in `Packages/Store/Tests/StoreTests/`, importing SSHKit; T1's `Store/Package.swift` declares SSHKit as a test-only dependency) logs in to the droplet with a key from `KeyGenerator` whose public line the test appends to `authorized_keys` over a password session.
### Depends on
T2, T3

## Task T5: TermUI terminal view and debug session
### Tree org map
```
Packages/TermUI/Sources/TermUI/
├── TerminalIO.swift          [NEW]
├── TerminalHostView.swift    [NEW]
└── TerminalTheme.swift       [NEW]
Packages/TermUI/Tests/TermUITests/
├── TerminalReplayTests.swift [NEW]
└── Fixtures/vim-startup.bin  [NEW]
App/Sessions/SessionBridge.swift [NEW]
App/Debug/DebugConnectView.swift [NEW]
App/RootView.swift            (wiring line only)
```
### List of changes
1. `TerminalIO` protocol: `send(_ bytes: [UInt8])`, `resized(cols:rows:)`, and an `incoming: AsyncStream<Data>` the view consumes.
2. `TerminalHostView`: a `UIViewRepresentable` around SwiftTerm's `TerminalView`. It feeds incoming bytes in and forwards typed bytes and size changes through `TerminalIO`. Font size and theme come from `TerminalTheme` (a dark and a light theme). Hooks for T6: optional `accessoryView: UIView?` and `keyCommands: [UIKeyCommand]` parameters, and a `TerminalController` handle with `clear()`, `increaseFont()`, `decreaseFont()` and `send(_:)`.
3. `SessionBridge`: adapts an SSHKit `Session` to `TerminalIO`. It drains `session.output` once for the session's lifetime; each `incoming` access returns a fresh stream that first replays a bounded buffer of recent output (about 512 KB), so a view torn down and re-created for the same session (tab switch, moving to another iPad window) re-renders. Detaching a view never ends the session's output.
4. `DebugConnectView` (`#if DEBUG`): host, user and password fields that open a `TerminalHostView` over an `SSHConnection`. It trusts any host key and is clearly labelled debug-only. One wiring line in `RootView` links to it under `#if DEBUG`.
### Reason for changes
This proves the terminal end to end before the host UI exists, and keeps TermUI free of any SSH dependency.
### Done when
- `scripts/test.sh TermUI` passes `TerminalReplayTests`, which feeds `Fixtures/vim-startup.bin` into the terminal and asserts the cursor position and the status line text.
- Manual: in a DEBUG build on the simulator, connecting to a do-lab droplet via the debug screen runs `vim`, `htop` and `tmux` with correct rendering, and rotating the device reflows the shell (`tput cols` changes). Record the result in the PR.
### Depends on
T2

## Task T6: Keyboard input
### Tree org map
```
Packages/TermUI/Sources/TermUI/Input/
├── ExtraKeysBar.swift          [NEW]
├── HardwareKeyCommands.swift   [NEW]
└── KeyEncoder.swift            [NEW]  (byte encodings shared by the bar and tests)
Packages/TermUI/Tests/TermUITests/KeyEncodingTests.swift [NEW]
docs/testing/keyboard-matrix.md [NEW]
```
### List of changes
1. `ExtraKeysBar`: an `inputAccessoryView` with Esc, Ctrl (sticky), Alt (sticky), Tab, arrow keys, `|`, `~`, `/`. It is built from a `TerminalController`, so it reaches the terminal view (sticky modifiers, application cursor mode) without the caller handing it one; one bar per terminal.
2. `HardwareKeyCommands`: `UIKeyCommand`s for Cmd+T (new tab), Cmd+W (close), Cmd+1…9 (switch), Cmd+K (clear), Cmd+= / Cmd+- (font size). Tab actions post notifications, with the sending window scene as the notification object, that T8 observes per window; Cmd+K and font size call T5's `TerminalController`. T8 passes `ExtraKeysBar` and these key commands into T5's `TerminalHostView` hooks. Ctrl+letter and Alt-as-Meta map to the correct escape sequences.
3. Caps Lock remapping is not done in the app (SwiftTerm's key handling cannot be intercepted and iPadOS still toggles Caps Lock). Users set it in iPadOS Settings › General › Keyboard › Hardware Keyboard › Modifier Keys; the matrix tests with that set. (Owner decision, 2026-11-21.)
4. `docs/testing/keyboard-matrix.md`: the manual matrix (key, expected bytes, result) for an iPad + Magic Keyboard and for the software keyboard.
### Reason for changes
Typing feel is the main risk to retention (spec, Risks). It lives in TermUI so every session gets it.
### Done when
- `scripts/test.sh TermUI` passes `KeyEncodingTests` (Ctrl+A…Z, Alt+letter, arrow keys in normal and application cursor mode, Esc, Tab).
- `docs/testing/keyboard-matrix.md` is filled in from an iPad with a Magic Keyboard, every row passing.
### Depends on
T5

## Task T7: Host list, editor and host-key trust
### Tree org map
```
App/Hosts/
├── HostListView.swift        [NEW]
├── HostEditorView.swift      [NEW]
├── HostKeyPromptView.swift   [NEW]
├── HostKeyMismatchView.swift [NEW]
└── HostConnectionView.swift  [NEW]  (connect flow and auth prompts)
App/RootView.swift            (wiring line only)
```
### List of changes
1. `HostListView`: a searchable list of `Host`, with swipe to delete and tap to connect. It becomes the root content of `RootView` (one wiring line).
2. `HostEditorView`: label, hostname, port, user, auth method, key picker (from T4's keys), optional saved password (saved with `synchronizable` = `AppContainer.syncEnabledAtLaunch`), tmux command (an empty field saves nil). Save calls `Host.touch()`.
3. Tapping a host opens a `TerminalHostView` over a `SessionBridge` (T5). The connect flow's `verifyHostKey` closure looks up `KnownHostsStore`. Unknown → `HostKeyPromptView` (fingerprint, Trust / Cancel). Match → continue. Mismatch → `HostKeyMismatchView`: full screen, connection blocked, with only "Replace stored key" after a confirmation. Trust and Replace call `KnownHostsStore.trust` with `synchronizable: AppContainer.syncEnabledAtLaunch`.
4. `HostConnectionView` runs the connect flow and asks for what authentication needs: each keyboard-interactive server prompt is shown to the user (SecureField for non-echo items, TextField for echo items, covering 2FA), a missing password is asked for, and an encrypted key with no saved passphrase asks for its passphrase (with a "Save passphrase" switch, off by default; a saved passphrase takes the key's sync flag). A host whose `keyID` is not on this device (a synced host whose key did not sync, or a deleted key) shows "Key not on this device" with links to import or generate a key and to edit the host; it does not attempt auth. The tmux command is not sent here (T9's `TmuxAttach` does that).
### Reason for changes
This is the user's path to saved hosts and the TOFU decision from the spec.
### Done when
- Manual on the simulator: a host whose key was deleted in the key list shows "Key not on this device" when tapped.
- Manual on the simulator against a do-lab droplet: a new host shows the fingerprint prompt; after Trust, a reconnect does not prompt; after rebuilding the droplet with the same IP, the mismatch screen blocks the connection. Record the steps and results in the PR.
- `xcodebuild build -scheme TermApp -destination 'generic/platform=iOS Simulator'` succeeds.
### Depends on
T3, T4, T5

## Task T8: Sessions, tabs and iPad windows
### Tree org map
```
App/Sessions/
├── SessionManager.swift      [NEW]
├── SessionTabsView.swift     [NEW]
├── SessionSceneView.swift    [NEW]
└── SessionSwitcher.swift     [NEW]
App/Hosts/HostConnectionView.swift (hand-off only: the connected session goes to SessionManager)
App/TermApp.swift             (wiring lines only)
App/RootView.swift            (wiring line only)
```
### List of changes
1. `SessionManager` (`@Observable`, `@MainActor`): owns live sessions keyed by UUID, each a `Session` + `SessionBridge` + host ID. Open, close, list. A session lives in exactly one window at a time (showing it elsewhere moves it). A session's connection and bridge can be replaced in place (same id, for T9's reconnect), and its views follow the new bridge.
2. `SessionTabsView`: tabs within a window; it observes T6's Cmd+T / Cmd+W / Cmd+1…9 notifications and builds each `TerminalHostView` with T6's `ExtraKeysBar` and key commands. Each session entry has an `overlay: AnyView?` hook (nil by default) that the tab draws over the terminal; T9 uses it for the Reconnect prompt.
3. `SessionSceneView` + a second `WindowGroup(for: UUID.self)` in `TermApp` (wiring) so a session can open in its own iPad window.
4. `SessionSwitcher`: a sheet listing all live sessions across windows.
5. Hand-off from T7: when `HostConnectionModel` reaches `.connected`, the session and bridge are handed to `SessionManager` and shown as a tab; leaving the connect screen no longer closes a handed-off connection. Tab notifications from T6 are observed with the window's own scene as the object.
### Reason for changes
Multiple sessions and iPad windows were chosen in the interview. One manager makes T9's reconnect pass cover every window.
### Done when
- Manual on an iPad simulator: three concurrent sessions across two windows, each with independent output; Cmd+1…3 switches tabs. Recorded in the PR.
- `xcodebuild build -scheme TermApp -destination 'generic/platform=iOS Simulator'` succeeds.
### Depends on
T5, T6, T7

## Task T9: Reconnect and tmux auto-attach
### Tree org map
```
App/Lifecycle/
├── AppPhaseMonitor.swift      [NEW]
├── ReconnectCoordinator.swift [NEW]
├── TmuxAttach.swift           [NEW]
├── ReconnectPromptView.swift  [NEW]
└── ConnectFlow.swift          [NEW]  (connect flow extracted from HostConnectionView)
App/TermApp.swift              (wiring line only)
App/Hosts/HostEditorView.swift (tmux toggle only)
App/Hosts/HostConnectionView.swift (switch to ConnectFlow only)
Packages/SSHKit/Sources/SSHKit/Session.swift (probe requirement and default only)
Packages/SSHKit/Sources/SSHKit/SSHConnection.swift (probe and end-state mapping only)
Packages/SSHKit/Sources/SSHKit/SSHError.swift (timeout case only)
Packages/SSHKit/Tests/SSHKitTests/SSHConnectionIntegrationTests.swift (probe tests only)
```
### List of changes
1. `AppPhaseMonitor`: tracks the app-level phase (active when any scene is active, background when all are), not a single window's `scenePhase`.
2. `ReconnectCoordinator`: on the app becoming active, probe each `SessionManager` session that is still `.connected`. A session already `.disconnected` with no overlay (it dropped while the app was in the background) counts as dead without a probe. Sessions already showing an overlay, or in any other state (`.connecting`, `.authenticating`, `.awaitingHostKeyDecision`), are left as they are. Reconnect dead ones silently only with saved credentials: key auth with a key that still exists and is unencrypted or has a saved passphrase, or password auth with a saved password. Every other host (password auth with no saved password, an encrypted key with no saved passphrase, a missing or deleted key, or keyboard-interactive auth) gets an in-tab `ReconnectPromptView` instead, set through T8's per-session `overlay` hook. `TermApp` starts the monitor and coordinator (one wiring line).
3. `TmuxAttach`: after a (re)connect, if the host has tmux attach on, send its command (default `tmux new -A -s main`). `Host.tmuxCommand` nil means off and an empty string means the default; T7's host editor gets an "Attach to tmux" toggle with an optional command field whose placeholder shows the default. The toggle replaces T7's free-text tmux field; off writes nil, on with an empty field writes `""`; saving calls `Host.touch()`. T7's field saves nil for an empty value, so hosts made before T9 merges keep attach off.
4. Reconnects run through T7's `HostConnectionModel` connect flow (same `KnownHostsStore` host-key check and auth prompts); a changed host key on reconnect blocks it exactly like a first connect. T9 extracts that flow from `App/Hosts/HostConnectionView.swift` into `App/Lifecycle/ConnectFlow.swift`, and `HostConnectionView` switches to it.
5. Dead-connection detection on becoming active is active, not passive: the `Session` protocol gains the requirement `func probe(timeout: Duration) async -> Bool` (true = healthy), so calls through `any Session` dispatch to the conformer (SSHKit `SSHConnection`: a keepalive with want-reply, then wait for any inbound traffic; probe timeout 3 s; on timeout the connection tears down as `.disconnected(.timeout)`, adding a `timeout` case to T2's `SSHError`). A `Session` protocol extension also gives it a default that returns `true` immediately, so test doubles (T12's fake `Session`) keep compiling; `SSHConnection` overrides it. For `testProbeDeadConnection`, `SSHConnection` gets an `internal` `closeSocketForTesting()` (reached through `@testable import`) that shuts down the socket without telling libssh2. Sessions found dead on that pass reconnect automatically under item 2's rules; a network error retries up to 3 times at 1 s, 2 s and 4 s, then shows the Reconnect / Close Tab overlay. A clean end is `.disconnected(nil)`; any `.disconnected(SSHError)` is a transport error. T9 makes `SSHConnection` map channel EOF, exit-status or exit-signal on the shell channel (a remote `exit`, or the shell killed) to `.disconnected(nil)`, and a local `close()` to `.disconnected(nil)` as well. Every other end from the server or the transport, including an SSH_MSG_DISCONNECT (libssh2 reports it like a socket drop), stays a transport error. A connection emits exactly one `.disconnected` state; the first end it detects decides `nil` versus an error. `SessionManager` marks a connection as closing before it calls `close()` (Close Tab) or swaps it out (T8's in-place replace), and `ReconnectCoordinator` drops end states from marked connections and from any connection that is no longer its session's current one. A session that ends cleanly while the app is active shows the in-tab overlay with Reconnect / Close Tab at once, before any later activation pass can see it, and does not reconnect silently. A transport error (reset, network down, probe timeout) at any time counts as dead and takes item 2's reconnect path with the retries above, even if it surfaces just after the app becomes active. Any end (clean or not) that happened while the app was in the background, or is read during the activation pass, counts as dead under item 2, so a server that disconnected an idle client still reconnects silently.
### Reason for changes
This is the M1 answer to iOS suspending sockets (spec, Risks row 1).
### Done when
- Manual on a device against a do-lab droplet with tmux installed: start `top` in the session, background the app for 10 minutes, reopen. The tab reconnects and shows the same tmux session with `top` still running. Recorded in the PR.
- A host with keyboard-interactive auth shows the Reconnect prompt instead of reconnecting silently.
- Manual, same droplet: with the app open, run `exit` in the session. The tab shows the Reconnect / Close Tab overlay and does not reconnect on its own; Reconnect brings the session back (into tmux when attach is on).
- Manual, same droplet, on a key-auth host: with a session open on Wi-Fi, background the app, switch the device to cellular only (Wi-Fi off) so its IP changes, wait 2 minutes, reopen. The session is marked dead (by the probe, or already disconnected) and reconnects without a prompt. Recorded in the PR.
- Manual, same host: turn on Airplane Mode, background the app, reopen with Airplane Mode still on. The first attempt and three retries (1 s, 2 s, 4 s) fail, then the Reconnect / Close Tab overlay shows.
- Manual: a host with the "Attach to tmux" toggle off reconnects to a plain shell; with it on and the command field empty, it runs `tmux new -A -s main`.
- With the `TERMAPP_TEST_*` vars set, `scripts/test.sh SSHKit` passes, including `SSHConnectionIntegrationTests.testProbeHealthy` (`probe(timeout:)` on a live connection succeeds) and `testProbeDeadConnection` (after `closeSocketForTesting()`, `probe(timeout:)` returns `false` and the connection ends `.disconnected(.timeout)` or `.disconnected` with a transport error within the timeout). `xcodebuild build -scheme TermApp -destination 'generic/platform=iOS Simulator'` succeeds.
### Depends on
T2, T7, T8

## Task T10: iCloud sync
### Tree org map
```
Packages/Store/Sources/Store/Sync/HostDeduper.swift [NEW]
Packages/Store/Tests/StoreTests/HostDeduperTests.swift [NEW]
App/Sync/SyncCoordinator.swift           [NEW]
App/Settings/SettingsView.swift          [NEW]
App/Settings/LicencesView.swift          [NEW]
App/Settings/Licences/*.txt              [NEW]  (GPLv3, libssh2, OpenSSL, SwiftTerm texts)
App/TermApp.swift                        (wiring line only)
App/RootView.swift                       (wiring line only)
```
### List of changes
1. `HostDeduper`: finds `Host` records sharing an `id`. The survivor is always the copy with the lowest `copyID` (synced, never changed, so every device picks the same one even mid-edit). If another copy has a newer `updatedAt` (truncated to whole milliseconds, CloudKit's precision; ties between such copies go to the lower `copyID`), all its fields except `id` and `copyID` are copied into the survivor first, `updatedAt` verbatim (no `touch()`). Then the other copies are deleted. Same-id copies come only from re-inserts (the item 4 fallback must re-save in place, not re-insert), the DEBUG action in item 3, or future import and restore paths. Scope is same `id` only: two hosts added separately for one server have different ids and both stay. Accepted: in that rare same-id case, an edit made to a non-survivor copy while another device deletes it can be lost; no path loses a whole host.
2. `SyncCoordinator`: a `@ModelActor` with its own context. Does nothing when `AppContainer.syncEnabledAtLaunch` is off. When on, it runs the deduper at launch and on `NSPersistentStoreRemoteChange`, debounced to 1 s. At launch with sync on it also makes every local item in `KeychainService.knownHosts` and `KeychainService.hostPassword` synchronizable (`KeychainStore.readAll(service:)` from T4, then `setSynchronizable(true, …)` only on entries whose `synchronizable` is false). It never makes a synced item local: turning sync off leaves already-synced passwords and fingerprints synced on every device, and only new ones stay on this device. Key items and passphrases keep their own per-key flag. Started from `TermApp` (wiring line).
3. `SettingsView`, opened from a gear `.toolbar` item that `RootView` adds around T7's content (wiring line; T10 does not edit `App/Hosts/**`): an "iCloud sync" toggle writing `sync.enabled`, with the note "Takes effect the next time the app opens", a link to T4's key list, a note pointing to iPadOS's Caps Lock modifier-key setting, and a "Licences" page: the app's GPLv3 notice with the source URL `https://github.com/peculiarengineer-mk/term-app`, and the full licence texts of libssh2 (BSD-3), OpenSSL 3 (Apache-2.0) and SwiftTerm (MIT). `sync.enabled` stays off by default (T3). In DEBUG builds only, a "Duplicate host" action inserts a copy of a chosen host with the same `id` and a new `copyID`, and a "Keychain items" list shows each item in `KeychainService.knownHosts` and `.hostPassword` with its sync flag (password items show the host's label next to its id).
4. Turning sync on uploads hosts made while it was off. Turning it off keeps local data, leaves the iCloud copy in place (hosts and already-synced Keychain items), and keeps the store writable; edits made while off upload the next time it is on. If SwiftData does not export hosts created before sync was on, T10 adds a one-time pass on the first launch with sync on that re-saves them, and says so in the PR.
### Reason for changes
Sync is separate from local storage so it only lands once storage is stable (spec, Risks).
### Done when
- `scripts/test.sh Store` passes `HostDeduperTests`, which use `ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)`: three copies of one id collapse to the lowest-`copyID` copy carrying the newest copy's fields; two `updatedAt` values in the same millisecond (t and t + 0.0004 s, t a whole second; truncation is `floor(x * 1000)`) count as equal (the survivor's fields stay); two newer copies in the same millisecond give their fields from the lower `copyID`; distinct ids are untouched; running the deduper twice changes nothing the second time.
- Manual, two devices (A, B) on one iCloud account, development build, results recorded in the PR:
    1. With sync off on both, add host H1 on A. Turn sync on on both, relaunch both, wait up to 2 minutes: H1 appears on B.
    2. Add H2 on B, edit H1's label on A, delete nothing: within 2 minutes both devices show H1 (new label) and H2, no duplicates.
    3. Delete H2 on A: it disappears on B.
    4. Connect to H1 on A and trust its fingerprint; save its password. On B, H1 connects with no TOFU prompt and no password prompt.
    5. Generate key K1 (sync off) and K2 (sync on) on A. Only K2 appears on B. On A, set H1's key to K1; on B, connecting to H1 shows "Key not on this device". Turn K2's sync off on A: the confirmation shows, K2 stays on A and disappears from B.
    6. DEBUG build on A: Settings → "Duplicate host" on H1, then relaunch A. After sync, both devices show one H1.
    7. Turn sync off on A and relaunch, then add host H3 on A and save its password: add, edit and delete still save locally, and nothing crosses to B. H1's password and fingerprint (synced in step 4) are still on B. In a DEBUG build, Settings on A lists H3's password as local (not synchronizable).
    8. Sign out of iCloud on B with sync on and relaunch: no crash, local hosts intact.
- After step 1, the `CD_Host` record type exists in the CloudKit Console's Development environment; "Deploy Schema Changes" to Production is done and recorded in the PR (TestFlight builds use Production).
- `grep -rl "GNU GENERAL PUBLIC LICENSE" App/Settings/Licences`, `grep -rl "Apache License" App/Settings/Licences` and `grep -r "github.com/peculiarengineer-mk/term-app" App/Settings` each find a match.
- `xcodebuild build -scheme TermApp -destination 'generic/platform=iOS Simulator'` succeeds.
### Depends on
T3, T4, T7

## Task T11: M1 test pass and TestFlight
### Tree org map
```
docs/testing/m1-checklist.md [NEW]
```
### List of changes
Worker part (the task's PR):
1. `docs/testing/m1-checklist.md` with:
    - A header block of `Field: value` lines (`Build: <n>` etc.): app version and build number, commit SHA, date, tester, iPhone model + iOS version, iPad model + iPadOS version, droplet IP and region, home-lab host's Tailscale name (MagicDNS or 100.x address).
    - "Owner prerequisites" (items 2–3 below) as a `- [ ]` list.
    - One table: `ID | Source | Steps | Expected | iPhone | iPad | Notes`. Result cells hold only `PASS`, `FAIL` or `N/A: <reason>`; Notes holds `-` when empty. The word FAIL appears nowhere else in the file.
    - Rows for the spec's M1 gate: generate an Ed25519 key; copy its public line; append it to `authorized_keys` on the droplet and on the home-lab box; connect to both with key auth using that key; the TOFU prompt appears; run vim, htop and tmux; background 10 minutes and return to the same tmux session.
    - One row per manual Done-when check from T4–T10 and T12, re-run on the TestFlight build (owner decision: re-run everything), with `Source` = `Tn Done-when <n>` (T10's steps as `T10 Done-when 2.<step>`; T10's one-time schema deploy is `N/A: done once, see T10 PR`) (T6 rows = every row of `docs/testing/keyboard-matrix.md`, on the iPad with a hardware keyboard; on the iPhone, the software-keyboard accessory row only). Also rows for import (OpenSSH, PEM, a passphrase key with and without "Save passphrase"), keyboard-interactive 2FA, rotation reflow, the Local Network prompt for a LAN address, and the Licences page. Rows that need a DEBUG build (T5's debug screen, T10 steps 6 and 7's DEBUG list) are `N/A: DEBUG only, see Tn PR`.
    - A teardown row: the do-lab droplet is destroyed after the run.

Owner part (after the PR merges; the worker cannot do these):
2. Apple accounts: App ID `com.peculiarengineer.termapp` with iCloud (CloudKit) and Push Notifications; CloudKit container `iCloud.com.peculiarengineer.termapp`; the App Store Connect app record (name, SKU, primary language, bundle ID); an internal tester group with the owner's Apple ID; an external tester group with Test Information (beta description, feedback email, contact details) and a privacy policy URL (a page stating the app collects no data); France removed from the app's availability (no French encryption declaration).
3. Test servers: a do-lab droplet with tmux and htop; the home-lab box on the tailnet with `sshd`, tmux and htop; the Tailscale iOS app installed, signed in and connected on the iPhone and iPad; the home-lab host reachable on Wi-Fi only and on cellular only.
4. Build: Organizer Validate App passes; Distribute App → Custom → App Store Connect → Export with "Manage version and build number" on; unzip the `.ipa` and run `codesign -d --entitlements - --xml Payload/TermApp.app`, which shows `aps-environment` = `production` and `com.apple.developer.icloud-container-environment` = `Production` (paste it into the checklist); upload with Transporter; no ITMS-9105x (privacy manifest) warnings in the upload result or email. Export compliance for each build: uses encryption, standard algorithms only (OpenSSL via SSH), mass-market exemption, not available in France.
5. Install from TestFlight (internal group) on both devices, run every row, fill in the header and results.
6. Publish the source (owner decision: public with the M1 TestFlight build, as a fresh history): rename the private repo to `term-app-private`, create a new public `peculiarengineer-mk/term-app`, and push one initial commit of the M1 tree from an orphan branch. The private history is never published. Do this before anyone outside the team installs the build, so the Licences page's source URL works.
7. Submit the build to the external group for Beta App Review.
### Reason for changes
This is the M1 gate in the spec.
### Done when
- Worker: `docs/testing/m1-checklist.md` exists with the header block and the table columns above, and every manual Done-when check from T4–T10 and T12 appears in its `Source` column (`grep -c 'T7 Done-when'` etc. is non-zero for each of T5, T6, T7, T8, T9, T10).
- Owner: `! grep -q 'FAIL' docs/testing/m1-checklist.md && ! grep -qE '\|[[:space:]]*\|' docs/testing/m1-checklist.md && ! grep -q -- '- \[ \]' docs/testing/m1-checklist.md && grep -qE '^Build: [0-9]+' docs/testing/m1-checklist.md` succeeds (no failures, no empty cells, every prerequisite ticked, build number filled in); the build is "Ready to Test" for the internal group and approved by Beta App Review for the external group; the repo is public.
### Depends on
T1, T2, T3, T4, T5, T6, T7, T8, T9, T10, T12

## Task T12: App-hosted Keychain tests
### Tree org map
```
TermApp.xcodeproj/**                       (new unit-test target TermAppTests, hosted by TermApp; added to the TermApp scheme's test action)
AppTests/KeychainHostedTests.swift         [NEW]
```
### List of changes
1. Add a unit-test bundle target `TermAppTests` with `TEST_HOST`/`BUNDLE_LOADER` pointing at TermApp, so tests run inside the app process with its Keychain entitlement. Its sources are the synchronized folder `AppTests/`. Add it to the shared TermApp scheme's Test action.
2. `AppTests/KeychainHostedTests.swift` (imports `Store`): Keychain save/read/overwrite/delete round-trip, `setSynchronizable` flip, `KnownHostsStore` trust/lookup/forget, and T4's `KeyStore` (add → list contains it once → `setSynchronizable` → list shows the new flag with no duplicate → delete → list empty). Also T5's `SessionBridge` with a fake `Session` (relying on `Session`'s default `probe(timeout:)` once T9 adds it): a second subscriber gets the replay then live output, and ending the session's output while a subscriber is attached finishes it without crashing. No skips on `-34018`. Only the synchronizable case may `XCTSkip`, and only when the simulator has no iCloud account (`errSecMissingEntitlement` or `errSecNotAvailable` on the synchronizable add).
### Reason for changes
T3's Keychain tests skip in the unhosted package runner (-34018), so Keychain storage is otherwise untested. Owner-approved exception to "no xcodeproj edits after T1".
### Done when
- `scripts/test.sh TermApp` succeeds, and its log shows `KeychainHostedTests` running with the non-synchronizable round-trip and the `KnownHostsStore` test passing, not skipped.
- `xcodebuild build -project TermApp.xcodeproj -scheme TermApp -destination 'generic/platform=iOS Simulator'` succeeds.
### Depends on
T3, T5

## Request coverage
The request is the whole app; this plan is phase M1 of the four milestones the user chose. Every requirement maps to a task here or to a later milestone:

| Requirement (from the interview) | Where |
| --- | --- |
| SSH into my boxes (Cloud VPS, home lab, Tailscale, ephemeral) | T2, T7, T11 (tested on do-lab droplets and the home lab over Tailscale) |
| iOS / iPadOS, Swift + SwiftUI, iOS 18+ | T1 |
| libssh2 wrapped in Swift | T1, T2 |
| Host list + keys | T3, T4, T7 |
| Keychain-only key storage | T3, T4 |
| TOFU host keys with a loud warning | T2, T7 |
| Multiple sessions/tabs, iPad windows | T8 |
| Hardware keyboard, extra-keys toolbar | T6 |
| Resilient sessions | T9 (reconnect + tmux); Mosh is M4 |
| iCloud sync | T10 |
| Rely on the Tailscale app | No code needed; covered by T11's Tailscale test row |
| Nothing collected | Design principles |
| GPL open source | `LICENSE` (in the repo's first commit), T10 (Licences page), T11 (repo public) |
| Tracked project | Repo (public from the M1 TestFlight build as a fresh single-commit history, T11 step 6) + sprint board; each task here is one issue |
| Port forwarding / SFTP | M2 (next plan) |
| Ephemeral box integration, DO personal access token | M3 |
| Mosh | M4 |
| Free core + one-time Pro unlock | M2 |

## New dependencies
- The project is new, so it has no existing dependencies to reuse. These three are unavoidable:
  - libssh2 1.11+: the user chose "libssh2 wrapped in Swift" in the interview.
  - OpenSSL 3: libssh2 needs a crypto backend, and its mbedTLS backend lacks Ed25519, the default key type.
  - SwiftTerm: a VT100/xterm emulator is required to render a terminal; writing one is out of proportion for M1, and SwiftTerm is the maintained native Swift option (MIT, GPL-compatible).
- No other new tools: the Xcode project is committed and uses synchronized folders, so no project generator is needed.

## Rollback
Each task lands as its own merge; reverting that merge commit rolls the task back. Nothing migrates user data in M1 (no users yet). The SwiftData schema is first defined in T3, so the first post-TestFlight schema change will need a `VersionedSchema`; that is noted for M2.

---
## File ownership map
- `TermApp.xcodeproj/**`, `Config/**`, `.gitignore`, `scripts/build-libssh2.sh`, `scripts/test.sh`, `App/Resources/**` → T1
- `Packages/*/Package.swift`, `Packages/SSHKit/Sources/SSHKit/SSHKit.swift`, `Packages/SSHKit/Tests/SSHKitTests/VersionTests.swift`, `Packages/Store/Sources/Store/Store.swift`, `Packages/Store/Tests/StoreTests/PlaceholderTests.swift`, `Packages/TermUI/Sources/TermUI/TermUI.swift`, `Packages/TermUI/Tests/TermUITests/PlaceholderTests.swift` → T1
- `App/TermApp.swift`, `App/RootView.swift` → T1 (wiring lines: T3, T5, T7, T8, T9, T10; see Design principles)
- `Packages/SSHKit/Sources/SSHKit/{Session,SSHConnection,SSHAuth,HostKey,SSHError,SocketPoller}.swift`, `Packages/SSHKit/Tests/SSHKitTests/SSHConnectionIntegrationTests.swift` → T2
- `Packages/Store/Sources/Store/Model/**`, `Packages/Store/Sources/Store/Keychain/**`, `Packages/Store/Tests/StoreTests/{HostPersistence,KeychainStore,KnownHostsStore}Tests.swift`, `App/AppContainer.swift` → T3
- `Packages/Store/Sources/Store/Keys/**`, `KeychainStore.readAll(service:)` (one added method in T3's merged file), `Packages/Store/Tests/StoreTests/{OpenSSHKeyFormat,KeyImporter,KeyGeneratorLogin}Tests.swift`, `Packages/Store/Tests/StoreTests/Fixtures/**`, `App/Keys/**` → T4
- `Packages/TermUI/Sources/TermUI/{TerminalIO,TerminalHostView,TerminalTheme}.swift`, `Packages/TermUI/Tests/TermUITests/TerminalReplayTests.swift`, `Packages/TermUI/Tests/TermUITests/Fixtures/**`, `App/Sessions/SessionBridge.swift`, `App/Debug/**` → T5
- `Packages/TermUI/Sources/TermUI/Input/**`, `Packages/TermUI/Tests/TermUITests/KeyEncodingTests.swift`, `docs/testing/keyboard-matrix.md` → T6
- `App/Hosts/**` → T7
- `App/Sessions/{SessionManager,SessionTabsView,SessionSceneView,SessionSwitcher}.swift` → T8 (plus the hand-off lines in `App/Hosts/HostConnectionView.swift`, after T7 merged)
- `App/Lifecycle/**` → T9 (plus extracting T7's connect flow from `App/Hosts/HostConnectionView.swift` for reconnects, the tmux toggle in `App/Hosts/HostEditorView.swift`, the `probe(timeout:)` requirement and default in `Packages/SSHKit/Sources/SSHKit/Session.swift`, `probe` and the end-state mapping in `SSHConnection.swift`, the `timeout` case in `SSHError.swift`, and the probe tests in `SSHConnectionIntegrationTests.swift`, all after their owners merged)
- `Packages/Store/Sources/Store/Sync/**`, `Packages/Store/Tests/StoreTests/HostDeduperTests.swift`, `App/Sync/**`, `App/Settings/**` → T10
- `docs/testing/m1-checklist.md` → T11
- `AppTests/**`, and the `TermAppTests` target and scheme test-action entries in `TermApp.xcodeproj` → T12 (owner-approved exception)
- `docs/SPEC.md`, `README.md`, `LICENSE`, `DEV_PLAN.md` → unowned, intentionally untouched

Verified: no file is touched by more than one task, apart from the declared wiring lines in `App/TermApp.swift` and `App/RootView.swift` and the exceptions listed in the ownership map (T4, T8, T9 after-merge edits; T12's xcodeproj test target).

## Out of scope
- `DOKit` and anything DigitalOcean-API related (M3).
- SFTP, port forwarding, and gating features behind Pro (M2).
- Mosh, `MoshSession`, UDP (M4).
- Secure Enclave keys, hardware security keys.
- Optional follow-ups not requested (candidates for M2): Face ID app lock, app-switcher privacy blur, the StoreKit 2 Pro purchase (lands with M2's "Pro unlock live").
- Any analytics, crash-reporting or logging SDK.
- Committing `Packages/SSHKit/Vendor/` build output.
- Editing `TermApp.xcodeproj` or anything in `Config/` after T1. A task that needs a new Info.plist key, entitlement or target must stop and ask.

## Acceptance for the phase
- [ ] `scripts/build-libssh2.sh` succeeds from a clean clone and `xcodebuild build -scheme TermApp -destination 'generic/platform=iOS Simulator'` then succeeds.
- [ ] `scripts/test.sh SSHKit`, `scripts/test.sh Store` and `scripts/test.sh TermUI` all pass, with `TERMAPP_TEST_*` set to a do-lab droplet.
- [ ] `xcodebuild build -scheme TermApp -destination 'generic/platform=iOS'` succeeds.
- [ ] `docs/testing/m1-checklist.md` and `docs/testing/keyboard-matrix.md` are fully passing.
- [ ] The build is on TestFlight for the internal group, approved by Beta App Review for the external group, and the repo is public.

## Suggested execution order
- T1 → (T2, T3 in parallel) → (T4 after T2+T3; T5 after T2) → T6 after T5; T7 after T3+T4+T5 → T8 after T5+T6+T7 → T9 after T2+T7+T8; T10 after T3+T4+T7; T12 after T3+T5, alone in its wave because it edits the Xcode project → T11

Critical path: T1 → T2 → T4 → T7 → T8 → T9 → T11. T2 and T3 can start as soon as T1 lands.

## Ready to hand off?
Not yet. M1 is tracked on the sprint board; hand off once the owner says go.
