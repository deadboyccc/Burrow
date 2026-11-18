#!/usr/bin/env bats
# The CLI without Docker: argument handling, init, config, links.

setup() {
	load ../helpers
	isolate
}

init_stealth() {
	burrow init --domain notes.example.org --ipv4 203.0.113.7 --quiet "$@"
}

@test "help and version" {
	run burrow help
	assert_success
	assert_output --partial "stealthy Telegram proxy"
	run burrow version
	assert_output --regexp '^burrow [0-9]+\.[0-9]+\.[0-9]+$'
}

@test "unknown commands and options fail clearly" {
	run burrow frobnicate
	assert_failure
	assert_output --partial "unknown command: frobnicate"
	run burrow init --bogus
	assert_failure
	assert_output --partial "unknown option: --bogus"
}

@test "init: stealth mode needs a domain, simple mode a cover domain" {
	run burrow init --ipv4 203.0.113.7
	assert_failure
	assert_output --partial "needs --domain"
	run burrow init --mode simple --ipv4 203.0.113.7
	assert_failure
	assert_output --partial "needs --cover-domain"
}

@test "init: writes a private, valid .env with a fresh secret" {
	run init_stealth --email me@example.org
	assert_success
	[[ $(stat -c %a "$BURROW_ENV_FILE") == 600 ]]
	grep -Eq '^SECRET=ee[0-9a-f]{32}6e6f7465732e6578616d706c652e6f7267$' "$BURROW_ENV_FILE"
	grep -q '^ACME_EMAIL=me@example.org$' "$BURROW_ENV_FILE"
}

@test "init: lowercases domains and infers simple mode" {
	run burrow init --cover-domain WWW.Example.COM --ipv4 203.0.113.7 --quiet
	assert_success
	grep -q '^BURROW_MODE=simple$' "$BURROW_ENV_FILE"
	grep -q '^COVER_DOMAIN=www.example.com$' "$BURROW_ENV_FILE"
}

@test "init: refuses to overwrite an existing secret without --force" {
	init_stealth
	first=$(grep ^SECRET= "$BURROW_ENV_FILE")
	run init_stealth
	assert_failure
	assert_output --partial "--force"
	run init_stealth --force
	assert_success
	[[ $(grep ^SECRET= "$BURROW_ENV_FILE") != "$first" ]]
}

@test "init: rejects invalid input before writing anything" {
	run burrow init --domain 'notes.example.org;id' --ipv4 203.0.113.7
	assert_failure
	[[ ! -e $BURROW_ENV_FILE ]]
	run burrow init --domain notes.example.org --ipv4 203.0.113.7 --port 70000
	assert_failure
	assert_output --partial PROXY_PORT
}

@test "init --subnet derives the decoy address" {
	init_stealth --subnet 10.250.1.32/28
	run burrow config get DECOY_IP
	assert_output 10.250.1.42
}

@test "config show redacts the secret" {
	init_stealth
	secret=$(burrow config get SECRET)
	run burrow config show
	assert_success
	assert_output --partial "DOMAIN=notes.example.org"
	refute_output --partial "$secret"
	assert_output --partial "SECRET=${secret:0:6}…"
}

@test "config set validates, and rolls back on error" {
	init_stealth
	run burrow config set PROXY_PORT 8443 ACME_EMAIL ops@example.org
	assert_success
	[[ $(burrow config get PROXY_PORT) == 8443 ]]
	before=$(<"$BURROW_ENV_FILE")
	run burrow config set PROXY_PORT 99999
	assert_failure
	[[ $(<"$BURROW_ENV_FILE") == "$before" ]]
	run burrow config set SECRET ee00
	assert_failure
	assert_output --partial "burrow rotate"
	run burrow config set NOT_A_KEY 1
	assert_failure
}

@test "link prints app and web links on stdout" {
	init_stealth
	secret=$(burrow config get SECRET)
	run burrow link
	assert_success
	assert_line --index 0 "tg://proxy?server=notes.example.org&port=443&secret=$secret"
	assert_line --index 1 "https://t.me/proxy?server=notes.example.org&port=443&secret=$secret"
	run burrow link --format secret
	assert_output "$secret"
}

@test "link uses LINK_HOST when set" {
	init_stealth --link-host 203.0.113.7
	run burrow link --format tg
	assert_output --regexp '^tg://proxy\?server=203\.0\.113\.7&port=443&secret=ee'
}

@test "rotate replaces the secret and keeps everything else" {
	init_stealth --email me@example.org
	old=$(burrow config get SECRET)
	run burrow rotate --yes
	assert_success
	new=$(burrow config get SECRET)
	[[ $new != "$old" ]]
	[[ $(burrow config get ACME_EMAIL) == me@example.org ]]
	[[ $(stat -c %a "$BURROW_ENV_FILE") == 600 ]]
}

@test "render writes state without Docker" {
	init_stealth
	run burrow render
	assert_success
	[[ -f $BURROW_STATE_DIR/mtg.toml && -f $BURROW_STATE_DIR/Caddyfile && -f $BURROW_STATE_DIR/compose.env ]]
}

@test "commands that need a config say how to create one" {
	run burrow link
	assert_failure
	assert_output --partial "burrow init"
}

@test "deploy validates its arguments before connecting anywhere" {
	run burrow deploy
	assert_failure
	assert_output --partial "root@203.0.113.7"
	run burrow deploy root@203.0.113.7 --ssh-port 0
	assert_failure
	run burrow deploy root@203.0.113.7 --dir relative/path
	assert_failure
}

@test "smoke --link rejects malformed links" {
	require_docker
	run burrow smoke --link "https://example.org/nothing"
	assert_failure
	assert_output --partial "not a proxy link"
}
