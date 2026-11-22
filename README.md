# term-app

Native iOS and iPadOS SSH client for VPSes, home-lab machines, tailnet hosts and short-lived
DigitalOcean droplets. Codename until launch.

- Swift + SwiftUI, iOS 18+
- Terminal: [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm)
- SSH: libssh2 1.11+ on OpenSSL 3, built as an XCFramework
- Licence: GPLv3 (see `LICENSE`)
- Collects no data

## Docs

- [`docs/SPEC.md`](docs/SPEC.md): product spec, decisions, milestones, architecture, security, risks
- [`DEV_PLAN.md`](DEV_PLAN.md): the current phase's task plan (M1)

Tasks are tracked as GitHub issues on the repo's sprint board.

## Milestones

| Milestone | Scope | Gate |
| --- | --- | --- |
| M1 Core terminal | Hosts, keys, TOFU host keys, SwiftTerm + keyboard, tabs and iPad windows, reconnect + tmux, iCloud sync | TestFlight build connects to a droplet and a home-lab box |
| M2 Forwards + SFTP | Local port forwards, SFTP browser, upload/download, Pro unlock live | Open a box's web UI; move a file |
| M3 DigitalOcean | Token in Keychain, droplets as hosts, create/destroy, push SSH key, forget host key on destroy | Spin up, SSH in, destroy, all from the app |
| M4 Mosh | Mosh client, UDP roaming session | Session survives a Wi-Fi to LTE switch |
