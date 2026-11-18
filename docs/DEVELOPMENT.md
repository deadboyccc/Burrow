# Development

See [CONTRIBUTING.md](../CONTRIBUTING.md) for the house rules.

## Running the tests

```bash
make test              # everything (needs Docker; e2e also needs internet)
make test-unit         # bash (bats) and Python (pytest), no network
make test-integration  # real mtg and Caddy parse every config; install dry runs in Debian
make test-e2e          # live stacks on 127.0.0.1 with real Telegram round trips
make lint              # shellcheck, shfmt, ruff, compose validation
```

Set `BURROW_E2E_OFFLINE=1` to skip only the checks that need Telegram.

## The test suites (275 tests)

| Suite | What it proves |
|---|---|
| **unit/** (bats, 117) | Validators reject injection; `.env` parsing never executes code; secrets, links, rendering and file permissions are right; `--help` and bad arguments never run commands; privacy defaults hold. |
| **tools/tests/** (pytest, 93) | The FakeTLS/MTProto client against a line-by-line port of mtg's server checks; a full Telegram round trip through a fake relay; probe verdicts and time limits against hostile servers; QR output. |
| **integration/** (34) | The real mtg binary accepts every config variant; Caddy validates every Caddyfile; the compose model is hardened; the host and install scripts plan the right steps in a Debian container. |
| **e2e/** (31) | Full stacks with real Telegram round trips; hardening as actually run; decoy pages, 404s and redirects; rotation; crash and hang recovery; block and allow lists; simple mode; `try`; `deploy` end to end; the installer for real, including an upgrade that removes dropped files and keeps the secret. |

CI runs every suite and a gitleaks secret scan on each push and pull request, and again
weekly to catch upstream changes (Telegram, images, certificate authorities).

## Releasing

1. Bump `BURROW_VERSION` (`lib/common.sh`), `tools/burrow_tools/__init__.py`,
   `tools/pyproject.toml` and `BURROW_INSTALLER_REF` (`install.sh`) together. A unit test
   checks that the installer pin matches.
2. Move the `[Unreleased]` notes in `CHANGELOG.md` under the new version.
3. Push a `vX.Y.Z` tag. The release workflow checks the version and the changelog, runs the
   unit tests, and publishes the source archive with checksums.

## Project layout

```
burrow                  the CLI (Bash)
install.sh              one-command server installer (curl | sudo bash)
lib/                    CLI modules: config, validation, rendering, secrets, links, compose
compose.yaml            hardened stack: mtg, decoy-init, decoy (Caddy), tools
compose.ipv6.yaml       overlay for ENABLE_IPV6=true
compose.nolog.yaml      overlay for LOGGING=off
site/                   decoy website template (copy to site.local/ to customise)
tools/                  burrow-tools image: FakeTLS/MTProto probe client, QR codes (Python)
scripts/                install-host.sh (server preparation), lint.sh, test.sh
deploy/                 systemd watchdog units, kernel tuning
tests/                  unit/, integration/, e2e/ (bats)
docs/                   the documentation
website/                GitHub Pages site
assets/digby.svg        the mascot
```

Generated at runtime and git-ignored: `.env`, `state/`, `.try/`, `site.local/`,
`.burrow-manifest`.
