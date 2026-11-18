# Security policy

## Reporting a vulnerability

Please **do not open a public issue**. Report privately through
[GitHub security advisories](https://github.com/deadboyccc/Burrow/security/advisories/new)
with steps to reproduce and the burrow version (`./burrow version`). You will get an
acknowledgement within a few days and a fix or mitigation plan as soon as possible.

Vulnerabilities in the proxy itself belong upstream at
[9seconds/mtg](https://github.com/9seconds/mtg/security), and in the web server at
[caddyserver/caddy](https://github.com/caddyserver/caddy/security). If a burrow release
needs to pick up their fix, tell us too.

## Scope

In scope: the `burrow` CLI and `lib/`, `install.sh`, the compose files, `scripts/install-host.sh`, the
systemd units, the burrow-tools image, and the defaults they ship with. For example: secret
leakage, command injection through configuration, a weaker-than-documented container
sandbox, or a fingerprint that singles out burrow deployments.

## Supported versions

Only the latest release receives fixes. Upgrade by re-running the one-command installer
(or `burrow deploy` from your computer); in a git clone, `git pull && ./burrow up`.

## Handling your secret

- The proxy secret lives in `.env` (mode 0600) and in links. Anyone holding either can
  use your proxy.
- If a link leaks, run `./burrow rotate`. Old links stop working immediately.
- Never paste `.env`, `burrow link` output or `state/share/` files into issues or chats.
  `burrow config show` redacts the secret for that reason.

See [docs/THREAT-MODEL.md](docs/THREAT-MODEL.md) for the full threat model.
