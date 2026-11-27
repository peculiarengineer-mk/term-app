# AmberTTY Privacy Policy

*Last updated: November 25, 2026*

AmberTTY is designed from the ground up for privacy. **AmberTTY collects no personal data, no analytics, and no telemetry.**

## Summary

- **Zero analytics or tracking:** AmberTTY contains no analytics SDKs, no third-party crash reporters, no advertising SDKs, and no cross-app or cross-site tracking (`NSPrivacyTracking` is `false`).
- **No AmberTTY backend:** AmberTTY does not operate relay servers, proxy servers, or user accounts.
- **App Store Privacy Nutrition Label:** Data Not Collected.

## SSH Connections & Session Data

- **Direct device-to-server connections:** SSH connections, SFTP file transfers, and local port forwards (`-L` tunnels) go directly from your device to the servers you configure.
- **In-memory terminal scrollback:** Terminal output and scrollback live in memory during an active session and are not written to disk by AmberTTY.
- **App Switcher protection:** AmberTTY blurs terminal and app views when moving to the iOS/iPadOS App Switcher, and optionally locks access behind Face ID or your device passcode.

## Keys, Passwords, and Cloud API Tokens

All sensitive credentials are stored using Apple's Keychain Services on your device:

- **Secure Enclave SSH keys:** On supported devices, newly generated Secure Enclave P-256 keys keep their private key material inside your device's hardware Secure Enclave (`kSecAttrAccessibleWhenUnlockedThisDeviceOnly`). They can never be exported or synced off the device.
- **Software SSH keys, passwords, and trusted host keys:** Imported keys, generated Ed25519 keys, optional saved key passphrases, optional saved host passwords, and Trust-On-First-Use (TOFU) host key fingerprints are stored in the Apple Keychain.
- **DigitalOcean and Cloudflare API tokens:** Cloud API tokens are stored strictly locally in your device Keychain (`kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`, `synchronizable: false`) and are **never** synced to iCloud.
- **Optional iCloud Sync (user-controlled):**
  - **iCloud sync toggle (Settings):** Off by default. When enabled, saved host configurations sync through your private Apple CloudKit container (`iCloud.com.peculiarengineer.termapp`), and saved host passwords and trusted host keys are promoted to Apple iCloud Keychain.
  - **Per-key iCloud Keychain sync:** Off by default. Software SSH keys (and an optional saved passphrase for an encrypted key) only sync through iCloud Keychain if you explicitly opt in for that key.
  - AmberTTY's developer cannot read or access any data in your iCloud account or iCloud Keychain.

## Photos & File Attachments

- When you attach an image to an AI agent session using Apple's system `PhotosPicker`, AmberTTY loads only the specific image you select. AmberTTY does not request full Photo Library access.
- Selected images are resized/encoded locally on your device and uploaded directly over SFTP to the SSH server you chose. They are never sent to AmberTTY or any third party.

## Third-Party Cloud APIs

- If you add a DigitalOcean personal access token or Cloudflare API token, AmberTTY communicates directly from your device with `api.digitalocean.com` or `api.cloudflare.com` solely to perform the actions you initiate (listing or managing Droplets, SSH keys, DNS records, or Zero Trust Tunnels).

## Device Permissions

- **Local Network (`NSLocalNetworkUsageDescription`):** Requested by iOS only if you connect to servers, home-lab machines, or local port-forwarded previews on your local area network.
- **Face ID (`NSFaceIDUsageDescription`):** Requested only if you enable Face ID / Passcode Lock in Settings. Authentication is handled on-device by Apple's `LocalAuthentication` framework; AmberTTY never receives biometric data.
- **Local Notifications:** Used only if **Agent Alerts** are enabled to notify you locally on-device when an AI coding agent waits for approval or finishes responding while AmberTTY is in the background or on another tab. No push notification server is used.

## In-App Purchases

- AmberTTY Pro is processed directly by Apple via StoreKit 2. AmberTTY checks entitlements using Apple's signed StoreKit transactions and never collects payment details or billing identities.

## Open Source & Contact

AmberTTY is open source under the GNU General Public License v3 (`LICENSE`). You can inspect the source code or ask privacy questions at:

- GitHub Repository: https://github.com/peculiarengineer-mk/term-app
- Support & Issues: https://github.com/peculiarengineer-mk/term-app/issues
