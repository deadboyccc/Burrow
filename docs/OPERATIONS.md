# Operations

Commands run on the server in `/opt/burrow`.

## Day-to-day tasks

| Task | How |
|---|---|
| Health, connected users, traffic | `./burrow status` |
| Full self-test | `./burrow smoke` |
| Logs | `./burrow logs -f mtg` / `./burrow logs decoy` (rotated: 3 × 10 MB per container) |
| Prometheus metrics | scrape `http://127.0.0.1:3129/metrics` on the server (`mtg_*`) |
| Change a setting | `./burrow config set KEY VALUE && ./burrow up` |
| Revoke every link | `./burrow rotate` |
| Upgrade burrow | re-run the install command (or `burrow deploy`); in a git clone, `git pull && ./burrow up` |
| Update container images only | `./burrow update` |
| Back up | `.env` (your secret) and, optionally, the `burrow_decoy-data` volume (certificates) |
| Move to a new server | install there, copy `.env` over, `./burrow config set PUBLIC_IPV4 <new IP> && ./burrow up`, point DNS at it; domain-based links keep working |
| Remove | `./burrow uninstall --purge` |

## Reliability

- **Checked start:** `up` only reports success once a real handshake succeeds. In stealth
  mode it then checks the website too, and says why if the certificate isn't ready yet.
- **Crash recovery:** every container restarts automatically (tested with `kill -9`).
- **Hang recovery:** a watchdog probes the proxy every 5 minutes. After three failed
  handshakes it recreates the proxy (tested with `docker pause`). It never restarts the proxy
  because of a problem in the probe itself.
- **Docker upgrades:** `live-restore` keeps the proxy serving while Docker restarts.
- **Precise changes:** `up` recreates only the containers whose configuration changed.
- **Certificates** renew automatically and survive `down` (only `down --volumes` deletes
  them), so restarts never hit Let's Encrypt's rate limits.
- **Time:** NTP is set up at install, and `doctor` checks clock drift. The disguised
  handshake depends on an accurate clock.

## Performance and capacity

The network is almost always the limit. Measured on a 1 vCPU / 1 GB VPS with a 100 Mbit/s
port:

| | Measured |
|---|---|
| Memory | mtg about 12 MiB, website about 12–16 MiB |
| Encryption speed (AES-256-CTR, 1 core) | about 37 Gbit/s, roughly 400× the port speed |
| Download / upload | about 94 / 120–200 Mbit/s (the port cap) |

What that serves at the same time:

| Usage | Simultaneous users |
|---|---|
| Normal mixed use (chats, photos, the odd video) | **about 300** |
| Mostly text | 1,500 or more (connections are capped at 8,192; each app opens 2–4) |
| Everyone watching video (1–3 Mbit/s each) | about 30–45 |

What makes it fast:
- **Kernel:** BBR congestion control with `fq`, larger queues and buffers, MTU probing,
  no slow restart after idle, and a cap on unsent data per socket. These matter most on the
  lossy, long-distance links censored users tend to have. The installer switches the network
  card to `fq` at once, not only after the next reboot.
- **Network path:** no userspace proxy. Ports are forwarded by the kernel, and client
  addresses are preserved.
- **Inside the proxy container:** every connection ends in the container's own network
  namespace, which doesn't inherit the host's TCP settings. So the container repeats the
  TCP tuning itself, and adds a larger accept queue, a wide port range for connections to
  Telegram, and 65,536 file descriptors.
- **Tuning knobs:** `CONCURRENCY`, `MTG_MEMORY_LIMIT`, `IDLE_TIMEOUT`.

Watch your provider's **monthly data allowance**: at full speed the server can move about
1 TB a day.

## Troubleshooting

| Symptom | Likely cause and fix |
|---|---|
| `up` says the website has no valid certificate | DNS doesn't point at the server yet, or ports 80/443 are closed in the provider's firewall. Check `dig +short DOMAIN`, then `./burrow logs decoy`. |
| Telegram shows "connecting…" forever | From a computer on another network (with burrow cloned): `./burrow smoke --link "$(ssh root@203.0.113.7 /opt/burrow/burrow link --format tg)"`. If that passes, your local network is blocking the server's IP. |
| Works on Wi-Fi but not mobile data, or the reverse | IP blocking on one network. Try `LINK_HOST` set to the IP, or a second server. |
| Many clients rejected | Check the clock with `./burrow doctor`. Clients with very wrong clocks are refused by design (`TIME_SKEW`). |
| `Pool overlaps with other one on this host` | Another Docker network uses `10.203.47.0/28`: `./burrow config set EDGE_SUBNET 10.77.1.0/28 DECOY_IP 10.77.1.10`. |
| Telegram is blocked *from the server* | Run a SOCKS5 egress (sing-box, WireGuard, …) listening on the Docker bridge gateway `10.203.47.1`, then `./burrow config set UPSTREAM_PROXIES socks5://10.203.47.1:1080`. Not `127.0.0.1`: mtg runs in a container. |
| Port 443 already in use | burrow must own 443. Move the other site into `site.local/` as the decoy, or use another server. |
| A custom page shows up unstyled | Inline `<style>` is blocked; move the CSS into `site.local/style.css` and link it. |
| No domain, but you want a real certificate | Use `<your-ip-with-dashes>.sslip.io` as the domain and set `LINK_HOST` to the IP. |

Still stuck? Run `./burrow doctor` and `./burrow logs`, then open an issue with the output
(remove secrets first).
