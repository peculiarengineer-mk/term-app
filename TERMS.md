# TermApp Terms of Use

*Last updated: November 25, 2026*

By downloading or using **TermApp**, you agree to these Terms of Use. If you downloaded TermApp from the Apple App Store, Apple's Standard Licensed Application End User License Agreement (EULA) also applies.

## 1. Software License

TermApp is open-source software licensed under the **GNU General Public License v3 (GPLv3)** (see [`LICENSE`](LICENSE) in the repository). Third-party open-source components retain their respective licenses, viewable in **Settings › About & Legal › Licences**.

## 2. TermApp Pro (In-App Purchase)

- TermApp's core SSH terminal, key management, command snippets, and iCloud sync are free.
- **TermApp Pro** is a **one-time, non-consumable in-app purchase** (`com.peculiarengineer.termapp.pro`) that unlocks Pro features (AI Agent Sessions, SFTP File Browser, Local Port Forwarding, and DigitalOcean & Cloudflare integrations). There is no recurring subscription.
- All purchases, billing, taxes, and refunds are handled exclusively by Apple through the App Store under Apple Media Services Terms and Conditions.
- You may restore an eligible previous purchase on devices signed in with the same Apple Account using **Restore Purchases** inside the TermApp Pro sheet.

## 3. Your Responsibilities & Remote Operations

You are solely responsible for:

- **Authorized access:** Only connecting to servers, networks, and cloud accounts that you own or have explicit authorization to access.
- **Credentials & API tokens:** Safeguarding your SSH private keys, passphrases, host passwords, and DigitalOcean/Cloudflare API tokens, and configuring appropriate API token permissions.
- **Remote and destructive actions:** TermApp gives you direct control over remote systems and cloud infrastructure, including:
  - Executing arbitrary shell commands and running AI coding agents on remote servers
  - Uploading, overwriting, renaming, or deleting remote files over SFTP
  - Staging, committing, or discarding uncommitted local changes in remote Git repositories
  - Creating, modifying, or deleting Cloudflare DNS records
  - Rebooting, powering off, or **permanently destroying DigitalOcean Droplets**
- Always verify target hosts, paths, DNS records, and confirmation dialogs before executing destructive actions. TermApp cannot undo remote commands, recover deleted files, restore discarded Git changes, or recover destroyed cloud resources.

## 4. Disclaimer of Warranties & Limitation of Liability

Consistent with the GNU General Public License v3 (Sections 15 and 16), TermApp is provided **"AS IS"**, without warranty of any kind, express or implied, including but not limited to implied warranties of merchantability, fitness for a particular purpose, or non-infringement.

To the maximum extent permitted by applicable law, the author and contributors are not liable for any damages (including loss of data, loss of server availability, cloud billing charges, or unintended infrastructure changes) arising out of your use of or inability to use TermApp.

## 5. Changes & Contact

These Terms may be updated with future releases. For questions or feedback, please see [`SUPPORT.md`](SUPPORT.md) or open an issue at:

- https://github.com/peculiarengineer-mk/term-app/issues
