# Deploying burrow, A to Z

From "I have nothing" to "my phone uses my own proxy" in about 20 minutes. Every step is
here, in order. Commands in `this style` are copy-paste ready. Replace the example values:

| Example value | Replace with |
|---|---|
| `203.0.113.7` | your server's public IPv4 address |
| `notes.example.com` | the domain (or subdomain) you will use |
| `you@example.com` | your email (for Let's Encrypt expiry notices) |

---

## A. What you need

- [ ] A **VPS** (virtual server): 1 vCPU, 1 GB RAM, Debian 12/13 or Ubuntu 22.04/24.04, a public IPv4.
- [ ] A **domain name**, or a subdomain of one you already have.
- [ ] A computer with a terminal (Linux, macOS, or Windows with WSL) and `ssh`.
- [ ] Optional but recommended: Docker on that computer too, for the final check from *your* side.

No domain at all? You can still deploy in **simple mode** (step F, variant 3). It is easier
to detect, so get a domain when you can.

## B. Choose a server

1. **Location.** Pick a country where Telegram is *not* blocked and that has good routes to
   your users (usually a nearby one). If you choose a server *inside* a censored country,
   you'll also need an upstream (`UPSTREAM_PROXIES`, see section M).
2. **Provider.** Any mainstream VPS provider works. Avoid providers whose IP ranges are
   widely blocked where your users are; ask people locally which ones work.
3. **Image.** Debian 13 or Ubuntu 24.04 LTS, x86-64 or ARM64.
4. **Firewall in the provider panel** (if it has one): allow inbound **TCP 22, 80, 443**.

## C. Create an SSH key and the server

On your computer:

```bash
ssh-keygen -t ed25519 -C "burrow"        # press Enter to accept the defaults; set a passphrase
cat ~/.ssh/id_ed25519.pub                 # copy this line
```

Create the server in your provider's panel and paste the public key where it asks for an
SSH key. When it boots, note its **IPv4 address** and check you can log in:

```bash
ssh root@203.0.113.7 'echo connected'
```

(Some images log in as `debian` or `ubuntu` instead of `root`. That's fine: burrow uses
`sudo` automatically.)

## D. Point your domain at the server

In your DNS provider (registrar, Cloudflare, …) create:

| Type | Name | Value | TTL |
|---|---|---|---|
| `A` | `notes` (for `notes.example.com`) | `203.0.113.7` | 300 |
| `AAAA` (optional) | `notes` | the server's IPv6 | 300 |

> **Cloudflare users:** set the record to **DNS only** (grey cloud), not proxied.

Choose a name that sounds like a website (`notes`, `blog`, `photos`, `garden`), not `proxy`
or `tg`. Wait a minute, then check:

```bash
dig +short notes.example.com          # must print 203.0.113.7
```

## E. Get burrow on your computer

```bash
git clone https://github.com/deadboyccc/Burrow.git burrow
cd burrow
./burrow version
```

Optional, but nice: try it locally first (needs Docker on your computer):

```bash
./burrow try && ./burrow try --down
```

## F. Deploy

### Variant 1: one command from your computer (recommended)

```bash
./burrow deploy root@203.0.113.7 --domain notes.example.com --email you@example.com
```

What happens, in order:

1. connects over SSH (and uses `sudo` if you're not root);
2. uploads burrow to `/opt/burrow` (never your `.env`; secrets are created on the server);
3. runs `scripts/install-host.sh`: Docker from Docker's signed repository, ufw firewall
   (SSH rate-limited, 80, 443), BBR tuning, NTP, unattended security upgrades, watchdog timer;
4. `burrow init` on the server: generates the secret;
5. `burrow up`: starts mtg + the decoy site and waits for the certificate;
6. `burrow smoke` on the server, then **again from your computer across the internet**;
7. prints your share link.

Useful flags: `--ssh-port 2222`, `-i ~/.ssh/other_key`, `--dir /srv/burrow`,
`--no-host-setup` (if you manage the server yourself), `--enable-ipv6`.
Re-running `deploy` later upgrades burrow and **keeps** the existing secret.

### Variant 2: by hand on the server

```bash
ssh root@203.0.113.7
apt-get update && apt-get install -y git
git clone https://github.com/deadboyccc/Burrow.git /opt/burrow && cd /opt/burrow
sudo scripts/install-host.sh --dir /opt/burrow            # --dry-run first if you're curious
./burrow init --domain notes.example.com --email you@example.com
./burrow up
./burrow smoke
```

### Variant 3: no domain (simple mode)

```bash
./burrow deploy root@203.0.113.7 --mode simple --cover-domain www.example.org
```

`--cover-domain` must be a popular HTTPS site that **is reachable where your users are**
(if it's blocked there, connections that name it will be too). Links will point at the
server's IP.

## G. Verify it works

1. **On the server:** `./burrow smoke` should print `all 8 checks passed`.
2. **From your computer:**
   `./burrow smoke --link 'tg://proxy?server=…'` (paste your link) should pass all checks.
3. **In a browser:** open `https://notes.example.com`. You should see an ordinary notes
   website with a valid padlock. That is what everyone except Telegram sees.
4. **Health overview:** `./burrow status`, and `./burrow doctor` for host checks.

If something fails, see [Troubleshooting](#troubleshooting) below.

## H. Make the decoy website yours

Thousands of identical template sites would be a fingerprint. On the server:

```bash
cd /opt/burrow
cp -r site site.local
nano site.local/index.html        # change titles, posts, wording; add pages or images
./burrow up                       # only the decoy container is recreated
```

Keep it boring and plausible: a personal blog, a portfolio, a recipe collection.
`./burrow doctor` stops warning once `site.local/` exists.

## I. Connect your phone

```bash
./burrow share            # prints a QR code + links (also saved in state/share/)
```

- **Phone:** scan the QR code with the camera, or open the `https://t.me/proxy?…` link,
  then tap **Connect proxy**.
- **Desktop:** click the `tg://proxy?…` link, or in Telegram go to *Settings → Advanced →
  Connection type → Use custom proxy → MTProto*, then enter server, port 443 and the secret
  (`./burrow link --format secret`).
- A shield icon or "Connected (proxy)" in Telegram's settings confirms it is in use.

## J. Share it with others

Send the `https://t.me/proxy?…` link (works even for people who can't open `tg://`
links) through a channel you trust. Anyone with the link can use your proxy.

- **Someone shouldn't have access any more?** `./burrow rotate`, then send the new link to
  everyone who should keep access. Old links die instantly.
- **Expect more users?** A 1 GB VPS handles a lot; watch `./burrow status` and bandwidth.

## K. Day-2 operations

| Task | Command |
|---|---|
| Health and traffic | `./burrow status` |
| Full self-test | `./burrow smoke` |
| Logs | `./burrow logs -f mtg` / `./burrow logs decoy` |
| Update burrow | from your computer: `git pull && ./burrow deploy root@203.0.113.7` |
| Update container images | `./burrow update` |
| Change settings | `./burrow config set KEY VALUE && ./burrow up` |
| Back up | copy `/opt/burrow/.env` somewhere safe (it holds the secret) |

The watchdog checks the proxy every 5 minutes and restarts it if it hangs
(`systemctl list-timers burrow-watchdog.timer`, logs: `journalctl -u burrow-watchdog`).
Certificates renew themselves. Security updates install themselves.

## L. Move to a new server (keep your links working)

1. Deploy burrow on the new server (step F, any domain; it is replaced next).
2. Copy the old `/opt/burrow/.env` over the new one, then run `./burrow up` there.
3. Point the DNS `A` record at the new IP. With `LINK_HOST` unset, links use the domain,
   so users don't need new links.

## M. If the server gets blocked

| Situation | What to do |
|---|---|
| The **IP** is blocked for your users | New server (step L). Links keep working if they use the domain. |
| The **domain** is DNS-poisoned | `./burrow config set LINK_HOST 203.0.113.7 && ./burrow up`, then share new links. |
| Telegram is blocked **from the server** | `./burrow config set UPSTREAM_PROXIES socks5://127.0.0.1:1080` (a local sing-box/WireGuard egress), `./burrow up`. |
| Probes still find it | Make the decoy richer (step H), add `DOPPELGANGER_URLS` with assets from your own site, keep port 443. |

## N. Uninstall

```bash
cd /opt/burrow
./burrow uninstall --purge     # containers, volumes, state, watchdog and .env
```

The firewall, sysctl tuning and Docker stay installed; remove them with your package manager if you like.

---

## Troubleshooting

| Problem | Fix |
|---|---|
| `cannot SSH to …` | Check the IP, the user (`root` vs `debian`/`ubuntu`), `--ssh-port`, `-i keyfile`. |
| "the decoy website has no valid certificate yet" | DNS doesn't point at the server yet (`dig +short`), or ports 80/443 are closed in the provider's firewall. Fix it, then `./burrow up`. Let's Encrypt allows a few failures per hour, so don't loop. |
| Smoke passes on the server but not from your computer | Something between you and the server blocks it (provider firewall, your ISP). Try from another network. |
| `Pool overlaps with other one on this host` | `./burrow config set EDGE_SUBNET 10.77.1.0/28 DECOY_IP 10.77.1.10 && ./burrow up` |
| Clients connect, then drop | Clock drift: `./burrow doctor`. On the server: `timedatectl status`. |
| Port 443 is already taken | Another web server is running. burrow must own 443: stop it, or serve that site as burrow's decoy via `site.local/`. |
| Anything else | `./burrow doctor`, `./burrow logs`, then open an issue with the output (remove secrets). |
