# term-app — iOS SSH Client Spec

As of 2026-11-21.

## Summary

term-app is a native iOS and iPadOS SSH client that stays connected to VPSes, home-lab machines,
tailnet hosts and short-lived droplets. It is a learning project that will ship publicly as GPL open
source, with a free core and a one-time Pro unlock.

It will ship in four milestones, each one a TestFlight build: M1 a solid terminal with saved hosts
and keys, M2 port forwarding and SFTP, M3 DigitalOcean integration, M4 Mosh. The app collects no
data.

## Decisions

| Area | Decision | Why |
| --- | --- | --- |
| Platform | iOS + iPadOS 18 and later | Modern SwiftUI, Observation framework, Swift 6 concurrency |
| Audience | Public App Store product | It is a learning project, but it ships for real |
| Stack | Swift + SwiftUI, SwiftTerm for the terminal | Native keyboard, Keychain and lifecycle control |
| SSH library | libssh2 1.11 or later on OpenSSL 3, built as an XCFramework, with a Swift wrapper | Mature, has SFTP built in. Ed25519 needs the OpenSSL backend; 1.11 brings RSA SHA-2 signatures for OpenSSH 8.8+ servers |
| Licence | GPLv3, open source | Needed to ship Mosh. GPL alone does not settle the App Store conflict (see Risks) |
| Business model | Free core + one-time Pro in-app purchase | No server costs to cover; SSH users dislike subscriptions |
| Pro tier | SFTP, port forwarding, DigitalOcean integration | Power features; the core terminal stays free |
| Key storage | Keychain only (no Secure Enclave) | Simple; Ed25519 + RSA + ECDSA keys stored as Keychain items |
| Sync | iCloud: hosts in CloudKit, keys as syncable Keychain items (opt in) | Apple-native, no backend |
| Tailscale / LAN | Use the Tailscale iOS app; connect to 100.x or MagicDNS names | No extra work for us |
| Host keys | Trust on first use (TOFU) with a fingerprint prompt; block on mismatch; forget a droplet's key when it is destroyed | Safe default that suits short-lived boxes |
| DigitalOcean auth | Personal access token stored in Keychain | No OAuth app or backend needed |
| Terminal UX | Extra-keys toolbar, full hardware keyboard, multiple sessions/tabs and windows | Chosen in the interview |
| Privacy | No data collected: no analytics, no crash SDK | App Store label: Data Not Collected |
| Testing | do-lab droplets + own home lab over Tailscale | Real servers; also tests the DO flow |
| Name | Codename term-app until launch | Naming is deferred |

## Milestones

Each milestone has to pass its gate on real servers before the next one starts. Every gate build
goes to TestFlight, and M1 is the first public release candidate.

| Milestone | Scope | Gate |
| --- | --- | --- |
| M1 Core terminal | Hosts, keys, TOFU; SwiftTerm + keyboard; tabs, iPad windows; reconnect + tmux; iCloud sync | TestFlight build connects to a droplet and a home-lab box |
| M2 Forwards + SFTP | Local port forwards; SFTP browser; upload/download; Pro unlock live | Open a box's web UI; move a file |
| M3 DigitalOcean | Token in Keychain; droplets as hosts; create/destroy; push SSH key; forget key on destroy | Spin up, SSH, destroy from the app |
| M4 Mosh | Mosh client; UDP roaming session; survives network switch and sleep | Session lives through Wi-Fi to LTE |

M1 is done when a TestFlight build connects to a do-lab droplet and to a home-lab box over Tailscale,
using a generated Ed25519 key, and survives a trip to the background via reconnect + tmux. The M1
build goes to internal and external TestFlight testers, and the source repo goes public with it.

## Architecture

The app is one SwiftUI target on top of local Swift packages:

| Package | Holds | Talks to |
| --- | --- | --- |
| `TermUI` | SwiftTerm view, extra-keys bar, hardware keyboard | the app's session bridge |
| `SSHKit` | `SSHConnection` actor; PTY, SFTP, forwards; libssh2 XCFramework; `MoshSession` (M4) | your servers, over the internet or Tailscale |
| `Store` | SwiftData hosts, CloudKit sync, `KeychainStore`, known host keys | iCloud |
| `DOKit` (M3) | DigitalOcean API client, droplets as hosts, token in Keychain | DigitalOcean |

SSHKit is the core: one `Session` protocol (connect, write, resize, output stream, close) with
`SSHConnection` in M1 and `MoshSession` in M4. That way TermUI and the reconnect logic never change
between the two.

- **Concurrency.** Each connection is an `actor`. libssh2 runs non-blocking on a dedicated serial
  executor and is polled when its socket is readable.
- **Session lifecycle.** Drive suspend and reconnect from the app-level `scenePhase`, not each
  window's: on iPad one window can go to the background while others stay active. When the app
  becomes active, probe every connected session (a keepalive with want-reply, then a short wait for any
  inbound traffic), treat sessions that dropped while in the background as dead, and reconnect the
  dead ones, then re-run the host's tmux attach command if attach is on. Only key auth with an
  available key (unencrypted or with a saved passphrase), or password auth with a saved password,
  reconnects silently; any other host,
  including keyboard-interactive 2FA, prompts instead. A session that ends cleanly while the app is
  active (remote `exit`) shows Reconnect / Close Tab in the tab rather than
  reconnecting; a network error reconnects with retries.
- **Data model.** `Host` (UUID, label, hostname, port, user, auth method, key ref, tmux command,
  tags, source: manual or droplet, created and updated times, and a per-copy ID that breaks dedupe
  ties the same way on every device). `tmuxCommand` nil means tmux attach is off; an empty string
  means the default, `tmux new -A -s main`. Secrets are referenced by ID and live only in Keychain.

## Security

Keys and secrets never leave Apple's Keychain except through iCloud Keychain sync, which the user
opts in to.

- **Private keys.** Ed25519 is the default when a key is generated. The app also imports
  OpenSSH-format and PEM keys (Ed25519, ECDSA, RSA). Passphrase-protected keys are handed to
  `libssh2_userauth_publickey_frommemory` with the passphrase, because CryptoKit cannot decrypt
  OpenSSH's bcrypt-pbkdf format. Each key is a `kSecClassGenericPassword` item with
  `kSecAttrAccessibleAfterFirstUnlock`, so items stay readable while the device is locked after its
  first unlock (`WhenUnlocked` would be stricter and also syncs). Searches, updates and deletes use
  `kSecAttrSynchronizableAny`. Turning sync on or off for a key deletes the item and
  re-adds it.
- **Public key export.** Copy or share the `authorized_keys` line. M3 adds pushing the key to
  DigitalOcean as an account SSH key.
- **Passwords.** Saving one is optional; it is stored in Keychain under the host's ID. Saved
  passwords and trusted host-key fingerprints sync through iCloud Keychain when host sync is on;
  a key's saved passphrase follows that key's own sync switch, which starts off and is independent
  of host sync. Making a synced Keychain item local deletes it on every other device, so turning
  host sync off leaves already-synced passwords and fingerprints synced (only new ones stay local),
  and turning a key's switch off asks first, then removes that key from the other devices.
  Keyboard-interactive auth is supported, which covers 2FA prompts.
- **Host keys.** After the handshake, read `libssh2_hostkey_hash(..., LIBSSH2_HOSTKEY_HASH_SHA256)`
  and compare it with the SHA-256 fingerprint stored for that host and port. On first connect, show
  the fingerprint and ask the user to trust it. On a mismatch, block with a full-screen warning; the
  user can only continue by explicitly replacing the stored key. M3: when the app destroys a
  droplet, it drops that droplet's stored key.
- **DigitalOcean token.** Stored in Keychain as `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`,
  so it never syncs to iCloud Keychain or CloudKit. Recommended custom scopes: `droplet:create`,
  `droplet:read`, `droplet:delete`, `ssh_key:create`, `ssh_key:read`.
- **App lock (post-M1).** Optional Face ID / passcode gate on launch and on return from the background
  (`NSFaceIDUsageDescription` required).
- **Local network.** Connecting to LAN addresses (not Tailscale) triggers iOS's Local Network
  permission prompt, which needs `NSLocalNetworkUsageDescription`.
- **No telemetry.** No third-party SDKs. Crash reports come only through Apple's opt-in TestFlight
  and App Store diagnostics.
- **Session content.** Scrollback is in memory only and never written to disk. Post-M1: the iOS
  app-switcher screenshot is hidden behind a blur.

## Risks

| Risk | Impact | Mitigation |
| --- | --- | --- |
| iOS suspends the app soon after it goes to the background (often under a minute) and its sockets drop | Sessions die whenever the user switches apps | M1: detect the drop, reconnect when the app returns, and optionally auto-attach to tmux on connect. M4: Mosh. Don't rely on background-mode tricks; App Review rejects them. |
| Building libssh2 + OpenSSL 3 for iOS (device + simulator) | Setup time; Xcode upgrades can break the build | Script it once into an XCFramework and check in the build script. Stay on OpenSSL: libssh2's mbedTLS backend has no Ed25519. |
| Mosh is C++ with protobuf and needs UDP | M4 is the largest piece of work | Study Blink's mosh port; keep it isolated behind the same Session protocol |
| GPL + App Store | The App Store's terms add restrictions GPLv3 forbids. VLC was pulled in 2011 after a contributor objected. | GPL apps survive when every copyright holder accepts App Store distribution. Blink works because it owns its code and the mosh authors tolerate App Store builds. Keep a contributor licence agreement, or accept the risk. Check every dependency: SwiftTerm MIT, libssh2 BSD-3, OpenSSL 3 Apache-2.0, mosh GPLv3 + OpenSSL exception, protobuf BSD-3. |
| SwiftTerm on iPad with a hardware keyboard: Ctrl/Alt/Esc edge cases | Bad typing feel is the main reason users leave | Dedicated keyboard test matrix in M1; Caps Lock to Ctrl/Esc via the iPadOS Modifier Keys setting (an in-app remap is not possible with SwiftTerm) |
| SwiftData + CloudKit sync between iPhone and iPad | Duplicate or lost hosts. CloudKit resolves conflicts per record (last write wins), and SwiftData + CloudKit forbids `@Attribute(.unique)` | A dedupe pass by host UUID after each sync. Every attribute optional or defaulted, relationships optional, no `.deny` delete rule. Sync is its own task, added after local storage is stable. |
| Export compliance | Upload is blocked until the encryption questions are answered | Set `ITSAppUsesNonExemptEncryption`; answer standard encryption, mass-market exemption for each build. France is left out of availability (no French declaration). Whether the annual self-classification report is required is an open question before the App Store release |

## Open questions

- [ ] Final app name and App Store availability check
- [ ] Pro price point (one-time unlock)
- [ ] Contributor licence agreement for outside contributions, given the GPL + App Store risk
- [x] Is iCloud Keychain key sync on by default or off by default? Off: each key opts in.
- [ ] Is the annual US self-classification report required for the mass-market SSH encryption?
