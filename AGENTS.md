# AGENTS.md

Guidance for AI coding agents (and humans) working on **burrow**: a self-hosted Telegram
proxy (mtg in FakeTLS mode behind a real decoy website) in hardened Docker, driven by a Bash
CLI, with a Python probe tool. Mascot: Digby the mole (`assets/digby.svg`).

Read [CONTRIBUTING.md](CONTRIBUTING.md) for the contribution rules, and
[docs/DESIGN.md](docs/DESIGN.md) and [docs/DEVELOPMENT.md](docs/DEVELOPMENT.md) for the
architecture, test suites and project layout. This file adds how to work here, and the traps
that have already bitten.

## Priorities

Security first, then reliability, then performance. A change that makes the proxy easier to
detect, or less private, is a regression, however fast it is. Simple beats clever: no new
dependencies, services or settings without a clear need.

## How to work

- **Decide, don't ask.** Make the judgement call, keep it reasonable, and say what you
  chose and why in the commit message and the changelog.
- **Verify before you claim.** Every statement in docs, changelogs and commit messages must
  be checked against the code, a test, upstream source, or a live run. Measure performance
  claims; don't estimate them. If you can't verify it, don't write it.
- **Finish the job.** Code, tests, docs, changelog, and a green CI. A feature that isn't in
  the docs doesn't exist; a doc that's no longer true is a bug.
- **Small, reviewable commits.** Imperative mood; the body explains *why*.

## Commands

```bash
make lint            # shellcheck, shfmt, ruff, compose validation (scripts/lint.sh)
make fmt             # auto-format shell (tabs, shfmt) and Python (ruff)
make test-unit       # bats + pytest, no network, about a minute
make test            # everything: needs Docker and internet (scripts/test.sh all)
scripts/test.sh unit|integration|e2e
./burrow try         # throwaway local instance on 127.0.0.1; ./burrow try --down
```

GitHub Actions runs lint, gitleaks, unit, integration and e2e on every push to `main` and
every pull request (and weekly). End-to-end tests need real Docker and reach Telegram, so CI
is the authoritative run. Never call a release done while CI is red.

## Rules that keep it safe

- **Secrets never leave their place.** Never commit a real proxy secret, token or password,
  and never put one in argv, logs, test fixtures or memory files. Secrets reach containers
  through the environment (`BURROW_SECRET`), never the command line. Test fixtures use fake
  secrets marked `# gitleaks:allow`.
- **`.env` is data, not code.** It's parsed strictly and never `source`d. Every value that
  reaches a config file is validated in `lib/validate.sh`.
- **Pin everything:** images by digest, Python packages by hash, actions by commit SHA.
- **Containers stay hardened:** uid 65534, read-only root, `cap_drop: ALL`,
  `no-new-privileges`, memory and pid limits. Tests assert this; keep them passing.
- **Tests bind 127.0.0.1 only**, on random ports and random `/28` subnets, and clean up
  after themselves. Never start a public proxy from a test or a dev machine.
- **Privacy claims are exact.** Nothing records who connects: no access logs, mtg without
  debug logging. If you change logging, change `docs/THREAT-MODEL.md` in the same commit.

## Traps already found (don't reintroduce them)

- **Network namespaces don't inherit TCP settings.** Every proxied connection ends inside
  the mtg container, so host sysctls (`deploy/sysctl/99-burrow.conf`) don't reach it. The
  per-namespace keys are repeated in `compose.yaml`; a unit test keeps the two in step.
- **`default_qdisc` only applies to interfaces brought up later.** The installer switches
  the live uplink to `fq` itself.
- **mtg resolves names through DoH,** not Docker's DNS, so the decoy has a static IP.
- **Never define `fail` (or other bats-support/bats-assert names) in `lib/`.** Unit tests
  source the libraries; a `fail` there silently turned ~80 tests' assertions into no-ops.
  The status printers are `ok`, `warn`, `cross`.
- **Probe containers must not read stdin** (except `qr`): `burrow status` once swallowed the
  rest of an `ssh host 'bash -s' <script`. `tools_in_stack` and `tools_on_host` handle it.
- **`--help` never runs a command,** and bad flags fail before anything changes.
- **bats:** prefer one final assertion over `cmd || fail` inside loops, and check that a new
  test can fail (break the code once, watch it go red).

## Releasing

1. Bump the version in all four places together: `BURROW_VERSION` (`lib/common.sh`),
   `tools/burrow_tools/__init__.py`, `tools/pyproject.toml`, and `BURROW_INSTALLER_REF`
   (`install.sh`). A unit test checks the installer pin.
2. Move `[Unreleased]` in `CHANGELOG.md` (Keep a Changelog) under `## [X.Y.Z] - date`, and
   add the compare link at the bottom.
3. Update the counts and claims that changed: the test totals in `README.md`,
   `website/index.html` and `docs/DEVELOPMENT.md`; behaviour in `docs/`.
4. Push to `main`, wait for green CI, then push tag `vX.Y.Z`. The release workflow checks
   the version and the changelog and publishes the archive with `SHA256SUMS`.

## Docs style

- **Split by reader.** `README.md` is a compact front page; details live in `docs/`
  (DEPLOY, USAGE, CONFIGURATION, OPERATIONS, THREAT-MODEL, DESIGN, DEVELOPMENT). The website
  (`website/index.html`) mirrors the README's claims.
- **Plain, short and scannable:** tables for options and commands, numbered steps for
  procedures, and **bold** for the one thing a reader must not miss. Give exact commands,
  the reason behind each recommendation, and measured numbers rather than adjectives.
- Commit messages: the maintainer's identity (deadboyccc), with a `Co-Authored-By` line for
  the AI agent as the only trailer.
