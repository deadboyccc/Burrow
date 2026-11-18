# Usage

Commands run on the server in the install directory (`cd /opt/burrow`), or anywhere as
`/opt/burrow/burrow …`. Add `--help` to any command for its options; `--help` never runs
the command.

burrow needs Linux (or macOS) with Docker Engine 25+, Docker Compose 2.24.4+ and Bash 4.4+.
On Debian/Ubuntu servers the installer sets all of that up for you.

## Commands

**Set up**

| Command | What it does |
|---|---|
| `init --domain D` | Create `.env` with a fresh secret (`init --help` lists every flag). |
| `up [--no-wait]` | Apply the configuration, (re)start what changed, wait until the proxy answers, print links. |
| `try [--down]` | Throwaway local instance on 127.0.0.1, fully self-tested (`--down` removes it). |
| `deploy user@host …` | Install or upgrade on a server over SSH (`deploy --help`). |

**Share**

| Command | What it does |
|---|---|
| `link [--format tg\|tme\|secret]` | Print share links. |
| `share` | Links, a QR code in the terminal, and private PNG/SVG copies in `state/share/`. |
| `rotate [--yes]` | New secret: every old link stops working. Asks first; `--yes` skips the question. |

**Operate**

| Command | What it does |
|---|---|
| `status` | Containers, a live health check, connected clients, traffic. |
| `smoke [--link L] [--insecure] [--no-telegram]` | End-to-end self-test (below). |
| `doctor` | Checks the host, clock, BBR, DNS, `.env` and decoy, then runs mtg's own doctor. |
| `logs [-f] [mtg\|decoy]` | Container logs. |
| `restart` · `down [--volumes]` · `update` | Restart; stop (`--volumes` also deletes the certificates); pull the pinned images and recreate. |
| `config show` · `get KEY` · `set KEY VALUE …` | Inspect or change settings (see [Configuration](CONFIGURATION.md)). |
| `watchdog` | One health check, restarting what's stuck (a systemd timer runs it every 5 minutes). |
| `render` | Write the generated configs to `state/` without starting anything. |
| `uninstall [--purge]` | Remove containers, volumes, state and the watchdog (`--purge` also deletes `.env`). |

## Sharing your proxy

```bash
./burrow share
```

- **Anyone with the link can use the proxy.** Send it privately, the way you'd send a key.
- **Two link forms.** `https://t.me/proxy?…` works everywhere; `tg://proxy?…` opens the
  app directly. Telegram accepts the secret in hex (`ee…`) or base64.
- **QR codes are made offline.** mtg's own command would send your secret to a public QR web
  service; burrow renders QR codes locally.
- **Revoke access with `./burrow rotate`.** Old links stop working at once (they now just
  reach the decoy website). Send the new link to the people who should keep access.
- **One link per server.** mtg serves a single secret by design, so there are no
  per-person links. For individually revocable access, look at
  [telemt](https://github.com/telemt/telemt).
- **DNS trouble?** Links point at your domain by default. If DNS for it gets poisoned, set
  `LINK_HOST` to the server's IP: links keep working and the disguise stays the same.

## Self-tests

`./burrow smoke` checks the live proxy the way a Telegram app (and a censor) would:

1. a valid client completes the disguised handshake;
2. **Telegram answers through the proxy** (a real request to a Telegram data centre);
3. a replayed handshake is refused;
4. a client whose clock is 10 minutes off is refused;
5. a wrong secret gets the website, not the proxy;
6. browsers and probes see a real website over real TLS;
7. plain-HTTP scanners get a normal web-server answer;
8. metrics are served on 127.0.0.1 only.

`./burrow smoke --link 'tg://proxy?…'` runs the same checks (minus the last one) against
**any** proxy link, from any machine with Docker. No `.env` is needed, so it's ideal for
testing your server from another network.
