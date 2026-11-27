# AmberTTY Support & Troubleshooting

Need help with AmberTTY, found a bug, or want to request a feature?

## Getting Help

- **GitHub Issues (Bug Reports & Questions):** https://github.com/peculiarengineer-mk/ambertty/issues
  - Please include your iOS/iPadOS version, AmberTTY version (**Settings › About & Legal › Version**), and steps to reproduce.
  - **Security reminder:** Never paste private SSH keys, passphrases, host passwords, or DigitalOcean/Cloudflare API tokens into an issue.
- **TestFlight Feedback:** If you are testing a TestFlight beta build, you can also send feedback and screenshots directly from the TestFlight app. (TestFlight builds unlock AmberTTY Pro features for testing.)

---

## Frequently Asked Questions

### Why do AI Agent sessions use `tmux`?

iOS and iPadOS suspend apps shortly after you switch away from them and close background network sockets. Running AI agents (`claude`, `agy`, `codex`, `aider`, `opencode`, or custom presets) inside `tmux` keeps the agent process running on your server even if your device sleeps or loses network connectivity.

When you relaunch the same agent in the same project directory, AmberTTY automatically reattaches to its persistent `tmux` session (`termapp-ai-<agent>-<project>`).

**Installing `tmux`:**
- When you open **Launch AI Agent**, AmberTTY checks whether `tmux` is installed on the target host and detects available package managers (`brew`, `apt`, `dnf`, `yum`, `pacman`, `apk`, `zypper`, `pkg`).
- If `tmux` is missing, tap the **Install tmux** card. If your server requires an interactive `sudo` password, tap **Install in Terminal** to run the install command interactively.
- When launching `tmux` and agent CLIs, AmberTTY prepends `$HOME/.local/bin`, `$HOME/.cargo/bin`, `/opt/homebrew/bin`, and `/usr/local/bin` to `PATH`.

---

### Should I use a Secure Enclave key or an Ed25519 key?

- **Secure Enclave P-256 (default on supported devices):**
  - The private key is generated inside your device's hardware Secure Enclave (`kSecAttrAccessibleWhenUnlockedThisDeviceOnly`).
  - It can **never** be exported, copied, or synced to iCloud.
  - Best for maximum hardware-backed security on a single device.
- **Ed25519:**
  - Stored in the Apple Keychain and supports optional **Sync via iCloud Keychain** (per key, opt-in) if you use AmberTTY across iPhone and iPad.
  - Automatically selected as the fallback on devices or simulators without a Secure Enclave.
- **Imported Keys:**
  - AmberTTY supports OpenSSH and PEM keys (Ed25519, ECDSA, RSA). Encrypted keys remain encrypted in Keychain, and saving their passphrase is optional.

To authorize a key on a server, copy or share its public key from the **Keys** tab and append it to `~/.ssh/authorized_keys` on your server (or push it to DigitalOcean from your key details view).

---

### What minimal API permissions do DigitalOcean & Cloudflare need?

API tokens are stored **only on this device** (`ThisDeviceOnly` Keychain item) and are never synced to iCloud. Create dedicated, least-privilege tokens with only the scopes below:

#### DigitalOcean Personal Access Token
- `droplet:create` — Spin up new Droplets
- `droplet:read` — List Droplets and public IPs
- `droplet:delete` — Destroy Droplets from the app
- `ssh_key:create` — Push device SSH keys to your account
- `ssh_key:read` — Select account SSH keys when creating a Droplet

#### Cloudflare API Token
- `Zone:DNS:Edit` — View zones and create, edit, or delete DNS records
- `Account:Cloudflare Tunnel:Read` — List Zero Trust Tunnels and exposed hostnames

---

### Why does AmberTTY ask for Local Network permission?

iOS requires Local Network permission (`NSLocalNetworkUsageDescription`) when connecting to SSH servers, home-lab machines, or dev servers on your LAN (such as `192.168.x.x` or `.local` hostnames).

If you accidentally denied permission, re-enable it in **iOS Settings › Privacy & Security › Local Network › AmberTTY**.

For Tailscale hosts (`100.x` or MagicDNS names), make sure the **Tailscale** iOS app is connected.

---

### How do I remap Caps Lock to Control or Escape on iPad?

Open **iOS Settings › General › Keyboard › Hardware Keyboard › Modifier Keys** and remap **Caps Lock** there.

---

### How do I restore AmberTTY Pro on another device?

Open **Settings › AmberTTY Pro › Restore Purchases** while signed into the same Apple Account used for the original purchase.
