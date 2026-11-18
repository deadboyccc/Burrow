# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project uses
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [1.1.4] - 2026-11-18

### Changed

- **Digby, redrawn from scratch** as a detailed illustration at four times the previous
  resolution:
  - dawn sky with sun rays, soft-edged clouds, and hills fading into the haze;
  - a meadow with grass and flowers, and textured soil around a shadowed burrow;
  - fur texture with rim lighting, glossy eyes and a highlighted nose;
  - beveled brass goggles with glass reflections on a stitched leather strap;
  - a knitted scarf streaming in the wind, and a shaded paper plane on a looping trail.

  It is still a single scalable SVG (20 KB), and reads clearly from favicon size up. The
  README and the website use it automatically.

## [1.1.3] - 2026-11-18

A documentation release. The 500-line README is now a compact front page plus focused
guides. There are no behaviour changes; upgrading is optional.

### Changed

- **README** is now a one-screen front page: what burrow is, the one-command install, a
  diagram, everyday commands, features, and a map of the documentation.
- **New focused guides in `docs/`**, one per reader:
  - `USAGE.md`: commands, sharing, revoking access, self-tests.
  - `CONFIGURATION.md`: installer variables, `.env` settings, your own decoy website.
  - `OPERATIONS.md`: day-to-day tasks, reliability, measured performance and capacity,
    troubleshooting.
  - `THREAT-MODEL.md`: what burrow protects against, what it doesn't, privacy, host
    hardening.
  - `DESIGN.md`: how a connection is handled, and why these technologies.
  - `DEVELOPMENT.md`: tests, CI, the release checklist, project layout.
- Capacity figures now come from a real benchmark of a 1 vCPU / 1 GB VPS: about 300
  simultaneous users with normal use.
- Cross-references now point at the new pages: the generated `.env`, `SECURITY.md`,
  `CONTRIBUTING.md` and the deployment guide. The website gains a "Docs" link.
- `burrow deploy` now uploads `docs/` and `CONTRIBUTING.md` too.

## [1.1.2] - 2026-11-18

A documentation release: what burrow records about the people who use your proxy, verified
against mtg's source and a live server. There are no behaviour changes; upgrading is optional.

### Fixed

- **The logging docs were wrong.** The README, `.env.example`, the comment in every
  generated `.env` and `compose.nolog.yaml` claimed that mtg logs client IPs with
  `LOGGING=on`. In fact mtg (v2.3.0, without `DEBUG`) logs at warning level only:
  - connection starts and blocklist/allowlist rejections are never written;
  - a client's IP appears only in a few connection-error warnings (for example when
    Telegram can't be reached);
  - `DEBUG=true` logs every connection with its IP.

### Changed

- The README's security section, the deployment guide and the website now say what is
  and isn't recorded: no connection logs by default, no decoy access logs, and a host
  firewall that logs only blocked packets. Anyone with root can still see live
  connections.
- New regression tests keep those guarantees: the decoy never gets an access log, and
  mtg runs without debug logging unless `DEBUG=true`.

## [1.1.1] - 2026-11-18

A bug-fix release from a second, independent review of the whole code base. Upgrade by
re-running the installer (or `burrow deploy`). Your secret and links are kept.

### Fixed

- **Changing the decoy site made every page unreadable (HTTP 403).** Files synced into
  a running site lost their read permission for the unprivileged web server. That happened
  after editing `site.local/`, changing the domain, or on January 1st (the year in the
  footer). Sites now stay readable, never go empty during a sync, and a symlinked site
  directory is refused.
- **`burrow <command> --help` ran the command** for most commands: `uninstall --help`
  uninstalled, and `rotate --help` replaced the secret. `--help` now only prints usage,
  and every command rejects arguments it doesn't know. `rotate` without a terminal
  requires `--yes`.
- Installer:
  - `BURROW_DRY_RUN` and `BURROW_SKIP_HOST_SETUP` failed open on values like `true`.
    They now accept 1/true/yes and 0/false/no, and reject anything else.
  - Upgrades remove files that a release dropped.
  - Upgrades install code with 0755/0644 modes, never group-writable.
  - Re-runs take firewall ports from the existing configuration, and report requested
    settings that differ instead of silently ignoring them.
  - Dry runs preview the real host plan and say "Dry run complete".
- `burrow smoke --link` accepts links whose secret is in base64 form (as `mtg access`
  prints them), not only the `ee…` hex form. Links are checked before Docker is needed.
- Probe client:
  - A blackholed address (for example a firewalled IPv6 address listed first) can no
    longer use up the whole connect budget; addresses now share it.
  - The TLS handshake in the HTTPS probe respects the time budget.
  - `--timeout` and `--retry-delay` are range-checked.
- `status` before the first `up` says so instead of failing with a generic error.
- `config set` never leaves a copy of the secret behind when it fails.
- The watchdog restarts mtg only when the probe reports it unhealthy, never because the
  probe tool itself failed.
- Link fields in error messages are escaped, so a crafted link cannot write control
  sequences to the terminal.
- `install-host.sh` also finds SSH ports held by a socket-activated `ssh.socket`.
- Validation rejects IPv6 together with a specific `BIND_ADDR` (which would have listened
  on loopback only) and paths containing backslashes. Simple-mode configs whose subnet
  changed keep loading.
- The decoy's Content-Security-Policy allows self-hosted fonts.
- Docs:
  - The upstream SOCKS example pointed at `127.0.0.1`, which is mtg's own container; it
    now uses the Docker bridge gateway.
  - Upgrade instructions no longer suggest `git pull` for installs without a git
    checkout.
  - The deployment guide states where server commands run.
  - The generated `.env` links to the right README section.
- Tests: stronger assertions, test servers that stop cleanly, and a realistic upgrade test
  (a page dropped between releases must disappear).

### Changed

- busybox 1.38.0 (pinned by digest) for the one-shot `decoy-init` helper (Dependabot #1).
- The website works on phones: commands wrap instead of overflowing.

## [1.1.0] - 2026-11-18

A one-command installer, plus a hardening pass from a full security audit of the
code base. Upgrade by re-running the installer, or with `git pull && ./burrow up`, or by
re-running `burrow deploy`. Your secret is kept either way.

### Added

- **`install.sh`: install on a server with one command**, configured through
  environment variables:
  `curl -fsSL https://raw.githubusercontent.com/deadboyccc/Burrow/main/install.sh | sudo BURROW_DOMAIN=notes.example.com bash`
  (or `BURROW_COVER_DOMAIN=…` for simple mode). It installs prerequisites, fetches the
  pinned release, prepares the host, creates the secret, starts the proxy, runs the
  smoke test and prints the links and QR code. Re-running it upgrades in place and keeps
  the secret. `BURROW_DRY_RUN=1` previews every step.
- Documented stealth mode without a domain: use your IP as a free wildcard-DNS name such as
  `203-0-113-7.sslip.io`, and point links at the IP with `LINK_HOST`. You still get a real
  certificate. Also documented the rules for custom decoy pages: CSS in files, because of
  the strict Content-Security-Policy, and a `404.html`.

### Security

- `install-host.sh` could lock you out of SSH: `sudo` drops `SSH_CONNECTION`, so a
  non-default SSH port was firewalled off. SSH now stays open on `--ssh-port` and on
  every port sshd listens on. If none can be determined, the firewall is left off.
- `burrow smoke --link` treats the server as hostile. Every probe has one overall time
  budget (a server could stall it forever with drips or empty TLS records).
  Server-supplied text is stripped of terminal escape sequences before printing.
- Dotfiles in `site.local/` (`.git`, `.DS_Store`, …) are no longer published or
  uploaded, and Caddy hides dotfiles too.
- `deploy` validates and quotes every value it sends to the server's root shell, and
  requires non-interactive sudo up front.
- `config show` hides SOCKS credentials, link errors no longer echo the secret, and
  `Secret` objects keep the key out of `repr()`.
- Unattended upgrades now include Docker's packages (runc and containerd fixes).

### Fixed

- **Failures were reported as success.** The command dispatcher switched off `set -e` for
  every command. For example, `deploy` printed "Deployed." after the server failed to
  start. Errors now stop the command with a non-zero exit, and `deploy` stops at the
  first failed step.
- The running decoy kept serving a deleted copy of the site after a re-render (e.g. from
  `doctor`, or a new year in the footer). The site is now synced in place, and `doctor`
  no longer re-renders under a running stack.
- `config set DOMAIN …` (or the mode) got stuck in a loop. The secret is now
  regenerated. `config set` validates all pairs before writing, and refuses to create a
  `.env`.
- `up` refuses to adopt the containers of another burrow installation on the same host.
- `install-host.sh` no longer aborts at the sysctl step on container VPSes (skipping the
  firewall). It refreshes package lists before installing, writes `daemon.json` before
  Docker starts (so `live-restore` applies), and validates `--dir`.
- The watchdog no longer restarts mtg when the probe tool itself failed, and is quiet on
  servers without a `.env`.
- `status` exits non-zero when the proxy is unhealthy. HTTP→HTTPS redirects keep a
  non-443 proxy port, and the IPv6 overlay follows `BIND_ADDR`.
- Validation covers every key in every mode. It also rejects `CONCURRENCY` with
  leading zeros and malformed IPv6 addresses.
- Probe verdicts are correct for resets after partial answers, partial TLS flights, HTTP
  servers that keep the connection open, and non-ASCII status codes. Out-of-range
  `--port`/`--dc` values are rejected, and the replay check reports "inconclusive"
  instead of a false alarm.
- A friendly error on bash < 4.4 (macOS's default bash). Host sysctl tuning no longer
  lowers `fs.file-max`.

### Changed

- Digby, the mascot, redrawn as a detailed dawn badge.

## [1.0.0] - 2026-11-18

First release. Digby the mole digs his first tunnel.

### Added

- **Stealth mode** (default): mtg v2.3.0 owns port 443 and relays valid FakeTLS clients to
  Telegram. Every other connection is spliced to a Caddy 2.11.9 decoy website on your own
  domain, with an automatic Let's Encrypt certificate, so DNS, SNI and the certificate
  agree.
- **Simple mode** for servers without a domain, impersonating a cover site.
- `burrow` CLI: `init`, `up`, `down`, `restart`, `status`, `logs`, `link`, `share`,
  `rotate`, `config`, `render`, `doctor`, `smoke`, `watchdog`, `update`, `try`,
  `deploy`, `uninstall`.
- `burrow deploy user@host`: idempotent one-command install or upgrade over SSH, with
  host preparation, server-side secret generation, and smoke tests from both ends.
- `burrow try`: a throwaway, self-tested instance on 127.0.0.1.
- `burrow smoke [--link]`: eight live checks, including a real `req_pq_multi` → `resPQ`
  exchange with Telegram through the proxy, replay, clock-skew and wrong-secret
  rejection, and the decoy's TLS and HTTP behaviour. Works against any proxy link.
- `burrow share`: links plus QR codes rendered offline (terminal, PNG, SVG, all mode 0600).
- `burrow rotate`: one-step revocation of all shared links.
- Hardened containers: uid 65534, read-only root filesystems, no capabilities,
  `no-new-privileges`, memory and PID limits, images pinned by digest.
- Config-hash labels: `burrow up` recreates exactly the containers whose config changed.
- `scripts/install-host.sh`: Docker from Docker's signed repository, ufw, BBR/fq tuning,
  NTP, unattended upgrades, and a systemd watchdog timer that recreates a hung proxy.
- Optional IPv6 (dual-stack with real client IPs), `LOGGING=off` (no logs at all),
  SOCKS5 upstreams, FireHOL/Spamhaus block lists, local block and allow lists, and
  doppelganger traffic mimicry.
- burrow-tools image: a from-scratch FakeTLS + obfuscated2 + MTProto client for probes,
  hash-locked Python dependencies.
- Tests: 77 bats unit tests, 59 pytest tests (checked against a port of mtg's
  server logic), 22 integration tests (real mtg and Caddy parse every config; the
  install script runs as a dry run in Debian), and 24 end-to-end tests on live stacks
  (crash and hang recovery, rotation, lists, simple mode, `try`, `deploy`).
- CI (lint, secret scan, unit, integration, e2e; weekly too), Dependabot, a tag-driven
  release workflow with checksums, and a GitHub Pages site starring Digby.
- Documentation: an in-depth README and an A-Z deployment guide (`docs/DEPLOY.md`).

[Unreleased]: https://github.com/deadboyccc/Burrow/compare/v1.1.4...HEAD
[1.1.4]: https://github.com/deadboyccc/Burrow/compare/v1.1.3...v1.1.4
[1.1.3]: https://github.com/deadboyccc/Burrow/compare/v1.1.2...v1.1.3
[1.1.2]: https://github.com/deadboyccc/Burrow/compare/v1.1.1...v1.1.2
[1.1.1]: https://github.com/deadboyccc/Burrow/compare/v1.1.0...v1.1.1
[1.1.0]: https://github.com/deadboyccc/Burrow/compare/v1.0.0...v1.1.0
[1.0.0]: https://github.com/deadboyccc/Burrow/releases/tag/v1.0.0
