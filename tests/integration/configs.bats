#!/usr/bin/env bats
# The real mtg and Caddy binaries accept every config burrow can render.

setup_file() {
	load ../helpers
	have_docker || return 0
	docker image inspect "$(pinned_image mtg)" >/dev/null 2>&1 || docker pull -q "$(pinned_image mtg)" >/dev/null
	docker image inspect "$(pinned_image decoy)" >/dev/null 2>&1 || docker pull -q "$(pinned_image decoy)" >/dev/null
}

setup() {
	load ../helpers
	require_docker
	isolate
}

# mtg_accepts: `mtg access` parses and validates the whole config file.
mtg_accepts() {
	burrow render >/dev/null
	run docker run --rm --network none --memory 64m --read-only --user 65534:65534 \
		-v "$BURROW_STATE_DIR/mtg.toml:/config.toml:ro" -v "$BURROW_STATE_DIR/lists:/lists:ro" \
		"$(pinned_image mtg)" access /config.toml
	assert_success
	assert_output --partial "\"hex\": \"$(burrow config get SECRET)\""
}

caddy_accepts() {
	burrow render >/dev/null
	run docker run --rm --network none --memory 128m \
		-v "$BURROW_STATE_DIR/Caddyfile:/etc/caddy/Caddyfile:ro" "$(pinned_image decoy)" \
		caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile
	assert_success
	assert_output --partial "Valid configuration"
}

@test "mtg: stealth defaults" {
	burrow init --domain notes.example.org --ipv4 203.0.113.7 --quiet
	mtg_accepts
}

@test "mtg: simple mode" {
	burrow init --cover-domain www.example.com --ipv4 203.0.113.7 --quiet
	mtg_accepts
}

@test "mtg: IPv6, upstream SOCKS5, allowlist, local lists, doppelganger, debug" {
	printf '203.0.113.0/24\n' >"$BATS_TEST_TMPDIR/list.netset"
	burrow init --domain notes.example.org --ipv4 203.0.113.7 --ipv6 2001:db8::7 --enable-ipv6 --quiet
	burrow config set UPSTREAM_PROXIES "socks5://u:p@10.0.0.2:1080 socks5://10.0.0.3:1080" \
		ALLOWLIST_URLS https://example.org/allow.netset LOCAL_ALLOWLIST "$BATS_TEST_TMPDIR/list.netset" \
		LOCAL_BLOCKLIST "$BATS_TEST_TMPDIR/list.netset" DOPPELGANGER_URLS https://notes.example.org/style.css \
		DNS_RESOLVER tls://9.9.9.9 PREFER_IP prefer-ipv6 DEBUG true TIME_SKEW 3s ANTI_REPLAY_SIZE 4mib >/dev/null
	mtg_accepts
}

@test "caddy: production (ACME) config" {
	burrow init --domain notes.example.org --ipv4 203.0.113.7 --email ops@example.org --quiet
	caddy_accepts
}

@test "caddy: staging CA" {
	burrow init --domain notes.example.org --ipv4 203.0.113.7 \
		--acme-ca https://acme-staging-v02.api.letsencrypt.org/directory --quiet
	caddy_accepts
}

@test "caddy: internal TLS (tests and try)" {
	burrow init --domain notes.example.org --ipv4 203.0.113.7 --tls internal --quiet
	caddy_accepts
}

@test "tools image runs unprivileged on a read-only root" {
	docker image inspect "burrow-tools:$(burrow version | cut -d' ' -f2)" >/dev/null 2>&1 ||
		docker build --quiet --target runtime -t "burrow-tools:$(burrow version | cut -d' ' -f2)" "$BURROW_ROOT/tools" >/dev/null
	run docker run --rm --read-only --network none --cap-drop ALL "burrow-tools:$(burrow version | cut -d' ' -f2)" --version
	assert_success
	run docker image inspect -f '{{.Config.User}}' "burrow-tools:$(burrow version | cut -d' ' -f2)"
	assert_output 65534:65534
}
