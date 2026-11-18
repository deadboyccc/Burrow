# Configuration

## Installer settings

The [one-command installer](../README.md#install) is configured with environment
variables:

```bash
curl -fsSL https://raw.githubusercontent.com/deadboyccc/Burrow/main/install.sh |
  sudo BURROW_DOMAIN=notes.example.com BURROW_EMAIL=you@example.com bash
```

| Variable | Meaning |
|---|---|
| `BURROW_DOMAIN` | Stealth mode: your domain (A record → this server). No domain? Use `203-0-113-7.sslip.io` (your IP with dashes). |
| `BURROW_COVER_DOMAIN` | Simple mode, the last resort: a popular HTTPS site reachable where your users are. |
| `BURROW_EMAIL` | Let's Encrypt account email (optional). |
| `BURROW_PORT` | Public proxy port (default `443`). |
| `BURROW_LINK_HOST` | What links point at (default: the domain, or the IP in simple mode). |
| `BURROW_ENABLE_IPV6` | `true` to also listen on IPv6. |
| `BURROW_SSH_PORT` | Your SSH port, if it can't be detected (ports sshd listens on are always kept open). |
| `BURROW_DIR` / `BURROW_REF` | Install directory (`/opt/burrow`) / release to install. |
| `BURROW_INIT_ARGS` | Extra `burrow init` flags, e.g. `"--subnet 10.77.1.0/28"`. |
| `BURROW_SKIP_HOST_SETUP=1` | Leave Docker, the firewall and kernel settings to you. |
| `BURROW_DRY_RUN=1` | Show every step, change nothing. |

On a server that is already installed, re-running the installer keeps the existing
configuration. It tells you if a variable you passed differs from it, and how to change it.

## Settings (`.env`)

Everything lives in `/opt/burrow/.env` (mode 0600; it holds your secret). Every key is
documented, with its default, in [`.env.example`](../.env.example). Change settings like this:

```bash
./burrow config set KEY VALUE [KEY VALUE ...]
./burrow up
```

`config set` validates all the values together and changes nothing if any is invalid. `up`
then recreates only the containers whose configuration changed. Changing `DOMAIN` (or the
mode) generates a new secret, because the secret embeds the domain, so links change too.

The settings you're most likely to touch:

| Key | Default | Notes |
|---|---|---|
| `DOMAIN` | | Stealth mode: your domain. |
| `LINK_HOST` | the domain | Put the server's IP here if DNS for your domain is poisoned. |
| `PROXY_PORT` | `443` | Keep 443: real HTTPS lives there. |
| `ENABLE_IPV6` | `false` | Also accept IPv6 clients, with their real addresses. |
| `UPSTREAM_PROXIES` | | `socks5://…` if Telegram is blocked *from the server* (see [Operations](OPERATIONS.md#troubleshooting)). |
| `BLOCKLIST_URLS` | FireHOL abusers + Spamhaus DROP | Known-bad networks, refreshed daily. |
| `LOCAL_BLOCKLIST` / `LOCAL_ALLOWLIST` | | Your own lists of networks to block or allow. |
| `LOGGING` | `on` | Warnings only (see [Threat model](THREAT-MODEL.md#privacy)); `off` keeps no logs at all. |
| `DEBUG` | `false` | Verbose logs, including every client's IP. Use only while troubleshooting. |
| `CONCURRENCY` | `8192` | Maximum simultaneous connections. |

## Your own decoy website

The decoy is what everyone who isn't a Telegram app sees. The bundled one is a template,
and the same template on many servers would be a fingerprint, so make it yours:

```bash
cp -r site site.local       # or upload your own pages into site.local/
$EDITOR site.local/index.html
./burrow up                 # only the website container is recreated
```

`site.local/` is used automatically, never touched by upgrades, and `{{SITE_NAME}}`,
`{{DOMAIN}}`, `{{YEAR}}` and `{{ACCENT}}` are filled in for you.

Rules for your pages:

- **CSS goes in files** (`<link rel="stylesheet" href="/style.css">`). The site sends a
  strict Content-Security-Policy that blocks `<style>` blocks, inline `style=""` and all
  scripts.
- Images and fonts must come from the site itself.
- Keep a `404.html`: scanners probe paths like `/wp-admin`.
- Dotfiles (`.git`, `.DS_Store`) are never published.
