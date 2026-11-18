#!/usr/bin/env bats

setup() {
	load ../helpers
	load_libs
	isolate
	STATE_DIR=$BURROW_STATE_DIR
	stealth_config
}

@test "mtg.toml (stealth): fronts to the decoy by IP on 8443" {
	run render_mtg_toml
	assert_output --partial "secret = \"$SECRET\""
	assert_output --partial 'bind-to = "0.0.0.0:3128"'
	assert_output --partial $'[domain-fronting]\nhost = "10.203.47.10"\nport = 8443'
	assert_output --partial $'[defense.anti-replay]\nenabled = true'
	assert_output --partial 'dns = "https://1.1.1.1"'
	assert_output --partial 'bind-to = "0.0.0.0:3129"'
	assert_output --partial 'debug = false'
}

@test "mtg.toml (simple): fronts to the cover domain itself" {
	BURROW_MODE=simple COVER_DOMAIN=www.example.com
	run render_mtg_toml
	assert_output --partial $'[domain-fronting]\nport = 443'
	refute_output --partial 'host = '
}

@test "mtg.toml: IPv6 listens dual-stack" {
	ENABLE_IPV6=true
	run render_mtg_toml
	assert_output --partial 'bind-to = "[::]:3128"'
}

@test "mtg.toml: blocklists on, off, and local files" {
	run render_mtg_toml
	assert_output --partial $'[defense.blocklist]\nenabled = true'
	assert_output --partial '"https://iplists.firehol.org/files/firehol_abusers_1d.netset", "https://iplists.firehol.org/files/spamhaus_drop.netset"'

	BLOCKLIST_ENABLED=false
	run render_mtg_toml
	assert_output --partial $'[defense.blocklist]\nenabled = false\ndownload-concurrency = 2\nurls = []'

	LOCAL_BLOCKLIST=/etc/block.netset
	run render_mtg_toml
	assert_output --partial $'[defense.blocklist]\nenabled = true\ndownload-concurrency = 2\nurls = ["/lists/blocklist.netset"]'
}

@test "mtg.toml: the allowlist is only enabled when it has entries" {
	run render_mtg_toml
	assert_output --partial $'[defense.allowlist]\nenabled = false'
	LOCAL_ALLOWLIST=/etc/allow.netset
	run render_mtg_toml
	assert_output --partial $'[defense.allowlist]\nenabled = true\ndownload-concurrency = 2\nurls = ["/lists/allowlist.netset"]'
}

@test "mtg.toml: upstream proxies and public addresses" {
	UPSTREAM_PROXIES="socks5://10.0.0.2:1080 socks5://u:p@10.0.0.3:1080"
	PUBLIC_IPV4=203.0.113.7 PUBLIC_IPV6=2001:db8::7
	run render_mtg_toml
	assert_output --partial 'proxies = ["socks5://10.0.0.2:1080", "socks5://u:p@10.0.0.3:1080"]'
	assert_output --partial 'public-ipv4 = "203.0.113.7"'
	assert_output --partial 'public-ipv6 = "2001:db8::7"'
}

@test "Caddyfile: internal TLS for tests, ACME settings for production" {
	run render_caddyfile
	assert_output --partial $'notes.example.org {\n\ttls internal'
	assert_output --partial "skip_install_trust"
	assert_output --partial "protocols h1 h2"
	assert_output --partial "admin off"
	assert_output --partial 'redir https://{host}{uri} permanent'

	TLS_MODE=acme ACME_EMAIL=me@example.org ACME_CA=https://acme-staging-v02.api.letsencrypt.org/directory
	run render_caddyfile
	refute_output --partial "tls internal"
	refute_output --partial "skip_install_trust"
	assert_output --partial $'\temail me@example.org'
	assert_output --partial $'\tacme_ca https://acme-staging-v02.api.letsencrypt.org/directory'
}

@test "site name and accent are derived from the domain" {
	run site_name notes.alice.dev
	assert_output Alice
	run site_name my-garden.example
	assert_output "My garden"
	a=$(site_accent notes.alice.dev)
	[[ $a == "$(site_accent notes.alice.dev)" && $a =~ ^#[0-9a-f]{6}$ ]]
}

@test "render_all: personalised site with no template markers left" {
	render_all
	run grep -rl '{{' "$STATE_DIR/site"
	assert_failure
	grep -q "<title>Example · notes</title>" "$STATE_DIR/site/index.html"
	grep -q "notes.example.org" "$STATE_DIR/site/notes/film.html"
}

@test "render_all: permissions keep the secret private" {
	render_all
	[[ $(stat -c %a "$STATE_DIR") == 700 ]]
	[[ $(stat -c %a "$STATE_DIR/mtg.toml") == 644 ]]
	[[ $(stat -c %a "$STATE_DIR/compose.env") == 600 ]]
	[[ $(stat -c %a "$STATE_DIR/share") == 700 ]]
	[[ $(stat -c %a "$STATE_DIR/site/index.html") == 644 ]]
}

@test "render_all: unchanged config keeps inodes, so running containers stay attached" {
	render_all
	site=$(stat -c %i "$STATE_DIR/site") conf=$(stat -c %i "$STATE_DIR/mtg.toml")
	render_all
	[[ $(stat -c %i "$STATE_DIR/site") == "$site" && $(stat -c %i "$STATE_DIR/mtg.toml") == "$conf" ]]
}

@test "render_all: hashes change exactly when their inputs change" {
	render_all
	before=$(<"$STATE_DIR/compose.env")
	mtg_before=$(grep MTG_CONFIG_HASH <<<"$before") decoy_before=$(grep DECOY_CONFIG_HASH <<<"$before")
	CONCURRENCY=1024
	render_all
	after=$(<"$STATE_DIR/compose.env")
	[[ $(grep MTG_CONFIG_HASH <<<"$after") != "$mtg_before" ]]
	[[ $(grep DECOY_CONFIG_HASH <<<"$after") == "$decoy_before" ]]
}

@test "render_all: a custom site.local/ wins over the template" {
	export BURROW_ROOT=$BATS_TEST_TMPDIR/root
	mkdir -p "$BURROW_ROOT/site.local"
	printf '<h1>{{SITE_NAME}} custom</h1>\n' >"$BURROW_ROOT/site.local/index.html"
	render_all
	[[ $(<"$STATE_DIR/site/index.html") == "<h1>Example custom</h1>" ]]
}

@test "render_all: simple mode still provides the bind sources compose checks" {
	BURROW_MODE=simple COVER_DOMAIN=www.example.com PUBLIC_IPV4=198.51.100.2
	SECRET=$(secret_new www.example.com)
	render_all
	[[ -f $STATE_DIR/Caddyfile && -d $STATE_DIR/site && -d $STATE_DIR/lists ]]
}

@test "render_all: local lists are copied in, and removed again" {
	printf '0.0.0.0/0\n' >"$BATS_TEST_TMPDIR/block.netset"
	LOCAL_BLOCKLIST=$BATS_TEST_TMPDIR/block.netset
	render_all
	[[ $(<"$STATE_DIR/lists/blocklist.netset") == 0.0.0.0/0 ]]
	LOCAL_BLOCKLIST=''
	render_all
	[[ ! -e $STATE_DIR/lists/blocklist.netset ]]
}

@test "compose_args picks profiles and overlays from the config" {
	compose_args
	[[ " ${COMPOSE_ARGS[*]} " == *" --profile stealth "* ]]
	[[ " ${COMPOSE_ARGS[*]} " != *compose.ipv6.yaml* ]]
	ENABLE_IPV6=true LOGGING=off BURROW_MODE=simple
	compose_args
	[[ " ${COMPOSE_ARGS[*]} " == *compose.ipv6.yaml* && " ${COMPOSE_ARGS[*]} " == *compose.nolog.yaml* ]]
	[[ " ${COMPOSE_ARGS[*]} " != *"--profile stealth"* ]]
}

@test "Caddyfile: redirects keep a non-standard proxy port and dotfiles stay hidden" {
	run render_caddyfile
	assert_output --partial 'redir https://{host}{uri} permanent'
	assert_output --partial 'hide .*'
	PROXY_PORT=8443
	run render_caddyfile
	assert_output --partial 'redir https://{host}:8443{uri} permanent'
}

@test "compose.env: values are single-quoted; IPv6 binding follows BIND_ADDR" {
	render_all
	grep -qx "BIND_ADDR6='::'" "$STATE_DIR/compose.env"
	grep -qx "BURROW_STATE_DIR='$STATE_DIR'" "$STATE_DIR/compose.env"
	BIND_ADDR=127.0.0.1
	render_all
	grep -qx "BIND_ADDR6='::1'" "$STATE_DIR/compose.env"
}

@test "render_all: changed site content is synced into the same directory" {
	export BURROW_ROOT=$BATS_TEST_TMPDIR/root
	mkdir -p "$BURROW_ROOT/site.local"
	printf 'one\n' >"$BURROW_ROOT/site.local/index.html"
	render_all
	inode=$(stat -c %i "$STATE_DIR/site")
	printf 'two\n' >"$BURROW_ROOT/site.local/index.html"
	render_all
	[[ $(stat -c %i "$STATE_DIR/site") == "$inode" ]]
	[[ $(<"$STATE_DIR/site/index.html") == two ]]
	run find "$STATE_DIR" -maxdepth 1 -name 'site.new*'
	assert_output ""
}

@test "render_all: re-synced sites stay readable by the unprivileged decoy" {
	export BURROW_ROOT=$BATS_TEST_TMPDIR/root
	mkdir -p "$BURROW_ROOT/site.local/notes"
	printf 'one\n' >"$BURROW_ROOT/site.local/index.html"
	printf 'old\n' >"$BURROW_ROOT/site.local/old.html"
	printf 'n\n' >"$BURROW_ROOT/site.local/notes/a.html"
	render_all
	printf 'two\n' >"$BURROW_ROOT/site.local/index.html"
	rm "$BURROW_ROOT/site.local/old.html"
	render_all
	[[ $(<"$STATE_DIR/site/index.html") == two && ! -e $STATE_DIR/site/old.html ]]
	run find "$STATE_DIR/site" -type f ! -perm 0644
	assert_output ""
	run find "$STATE_DIR/site" -type d ! -perm 0755
	assert_output ""
}

@test "render_all: a symlinked site directory is refused" {
	mkdir -p "$STATE_DIR" "$BATS_TEST_TMPDIR/elsewhere"
	ln -s "$BATS_TEST_TMPDIR/elsewhere" "$STATE_DIR/site"
	run render_all
	assert_failure
	assert_output --partial "not a symlink"
}

@test "Caddyfile: the CSP allows self-hosted fonts" {
	run render_caddyfile
	assert_output --partial "font-src 'self'"
}

@test "render_all: dotfiles in site.local are never published" {
	export BURROW_ROOT=$BATS_TEST_TMPDIR/root
	mkdir -p "$BURROW_ROOT/site.local/.git" "$BURROW_ROOT/site.local/notes"
	printf 'hi\n' >"$BURROW_ROOT/site.local/index.html"
	printf '[user]\nemail = me@example.org\n' >"$BURROW_ROOT/site.local/.git/config"
	: >"$BURROW_ROOT/site.local/notes/.DS_Store"
	render_all
	run find "$STATE_DIR/site" -name '.*'
	assert_output ""
	[[ -f $STATE_DIR/site/index.html ]]
}

@test "privacy: the decoy never keeps access logs" {
	run render_caddyfile
	refute_output --regexp '(^|[[:space:]])log([[:space:]]|$)'
	TLS_MODE=acme ACME_EMAIL=me@example.org
	run render_caddyfile
	refute_output --regexp '(^|[[:space:]])log([[:space:]]|$)'
}

@test "privacy: mtg runs without debug logging unless DEBUG=true" {
	run render_mtg_toml
	assert_line "debug = false"
	DEBUG=true
	run render_mtg_toml
	assert_line "debug = true"
}
