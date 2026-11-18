# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project uses
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

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

[Unreleased]: https://github.com/deadboyccc/Burrow/compare/v1.0.0...HEAD
[1.0.0]: https://github.com/deadboyccc/Burrow/releases/tag/v1.0.0
