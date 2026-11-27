# AmberTTY Terms of Use

*Last updated: November 27, 2026*

By downloading or using **AmberTTY**, you agree to these Terms of Use. If you downloaded AmberTTY from the Apple App Store, Apple's Standard Licensed Application End User License Agreement (EULA) also applies.

## 1. Software License

AmberTTY is open-source software licensed under the **GNU General Public License v3 (GPLv3)** (see [`LICENSE`](LICENSE) in the repository). Third-party open-source components retain their respective licenses, viewable in **Settings › About & Legal › Licences**.

## 2. AmberTTY Pro (In-App Purchases & Subscription)

- AmberTTY's core SSH terminal, key management, command snippets, and iCloud sync are free.
- **AmberTTY Pro** unlocks Pro features (AI Agent Sessions, SFTP File Browser, Local Port Forwarding, and DigitalOcean & Cloudflare integrations) and is offered via two plans:
  - **AmberTTY Pro Annual** (`com.peculiarengineer.termapp.pro.annual`): An **auto-renewable annual subscription** ($9.99/year, or local App Store equivalent) that includes a **7-day free trial** for eligible new subscribers. Payment is charged to your Apple Account upon confirmation of purchase (or at the end of the free trial period). Your subscription **automatically renews** at the annual price unless cancelled at least **24 hours before the end of the current period**. You can manage or cancel your subscription at any time in your **App Store Account Settings** (or via **Manage Subscription** inside the AmberTTY Pro sheet). Any unused portion of a free trial period is forfeited when you purchase a subscription or upgrade.
  - **AmberTTY Pro Lifetime** (`com.peculiarengineer.termapp.pro`): A **one-time, non-consumable in-app purchase** ($29.99, or local App Store equivalent) with no recurring subscription. If you later purchase Lifetime while on an active Annual subscription, be sure to cancel your Annual subscription in your App Store Account Settings if you do not want it to renew.
- All purchases, billing, taxes, and refunds are handled exclusively by Apple through the App Store under Apple Media Services Terms and Conditions.
- You may restore an eligible previous purchase or active subscription on devices signed in with the same Apple Account using **Restore Purchases** inside the AmberTTY Pro sheet.

## 3. Your Responsibilities & Remote Operations

You are solely responsible for:

- **Authorized access:** Only connecting to servers, networks, and cloud accounts that you own or have explicit authorization to access.
- **Credentials & API tokens:** Safeguarding your SSH private keys, passphrases, host passwords, and DigitalOcean/Cloudflare API tokens, and configuring appropriate API token permissions.
- **Remote and destructive actions:** AmberTTY gives you direct control over remote systems and cloud infrastructure, including:
  - Executing arbitrary shell commands and running AI coding agents on remote servers
  - Uploading, overwriting, renaming, or deleting remote files over SFTP
  - Staging, committing, or discarding uncommitted local changes in remote Git repositories
  - Creating, modifying, or deleting Cloudflare DNS records
  - Rebooting, powering off, or **permanently destroying DigitalOcean Droplets**
- Always verify target hosts, paths, DNS records, and confirmation dialogs before executing destructive actions. AmberTTY cannot undo remote commands, recover deleted files, restore discarded Git changes, or recover destroyed cloud resources.

## 4. Disclaimer of Warranties & Limitation of Liability

Consistent with the GNU General Public License v3 (Sections 15 and 16), AmberTTY is provided **"AS IS"**, without warranty of any kind, express or implied, including but not limited to implied warranties of merchantability, fitness for a particular purpose, or non-infringement.

To the maximum extent permitted by applicable law, the author and contributors are not liable for any damages (including loss of data, loss of server availability, cloud billing charges, or unintended infrastructure changes) arising out of your use of or inability to use AmberTTY.

## 5. Changes & Contact

These Terms may be updated with future releases. For questions or feedback, please see [`SUPPORT.md`](SUPPORT.md) or open an issue at:

- https://github.com/peculiarengineer-mk/term-app/issues
