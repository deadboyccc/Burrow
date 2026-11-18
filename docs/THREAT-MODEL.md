# Threat model

## What burrow protects against

| Threat | Defence |
|---|---|
| Deep packet inspection recognising Telegram | FakeTLS: the bytes on the wire look like TLS 1.3 to your own domain. |
| Active probing ("are you a proxy?") | Anything without the secret is passed to a real website with a real certificate. |
| Replay of a captured handshake | mtg's anti-replay cache, plus a ±5 s timestamp window. |
| DNS/IP/SNI mismatch checks | Stealth mode: your domain resolves to your server, which serves its own certificate. |
| Traffic-shape analysis | mtg's timing mimicry (`DOPPELGANGER_URLS`). |
| Abuse from known-bad networks | FireHOL and Spamhaus block lists, plus optional allow lists. |
| A compromised container | Non-root, read-only filesystems, zero Linux capabilities, `no-new-privileges`, memory and process limits. |
| Secret leakage | `.env` and share files are private (0600); secrets reach containers through the environment, never command lines; `config show` and logs hide them; QR codes are made offline. |
| Supply-chain tampering | Images pinned by digest, Python packages by hash, test tools by commit, CI actions by SHA. Dependabot updates images, Python packages and actions; the test and lint tools are bumped by hand. |
| Configuration injection | `.env` is read as data (never executed), unknown keys are ignored, and every value is validated before it reaches a config file. |

## What it does not do

- **It is not an anonymity tool.** Your hosting provider can see the server talking to
  Telegram, and Telegram sees the server's IP instead of your users'. Messages are
  protected by Telegram's own encryption either way.
- **It can't hide that the server exists.** A determined censor can still block its IP.
  Have a plan B: another server, `LINK_HOST`, `UPSTREAM_PROXIES`.
- **Anyone with the link can use the proxy.** Share it carefully, and `rotate` if it leaks.

## Privacy

By default **nothing records who connects**:

- mtg logs only warnings. Routine connections and block-list rejections are never logged.
  A client's IP appears only if its connection fails with an error, for example when
  Telegram can't be reached.
- The decoy website keeps no access logs.
- The host firewall logs only packets it blocks; proxy traffic is never logged.

Still worth knowing:

- Anyone with root on the server can see **live** connections.
- `DEBUG=true` logs every connection with its IP; use it only while troubleshooting.
- `LOGGING=off` keeps no container logs at all.

## Host hardening

`scripts/install-host.sh`, run by the installer, sets up:

- **Firewall (ufw):** inbound traffic is denied except rate-limited SSH, 80 and 443. SSH
  stays reachable on your SSH port and on every port sshd listens on. If no SSH port can be
  determined, the firewall is left off rather than risk locking you out.
- **Automatic security updates**, including Docker's own packages.
- **NTP time synchronisation.**
- **Docker** from Docker's signed repository, with `live-restore`.
- **The watchdog**, as a hardened systemd unit.

Docker publishes only the proxy and HTTP ports. Metrics stay on 127.0.0.1.

Found a vulnerability? See the [security policy](../SECURITY.md).
