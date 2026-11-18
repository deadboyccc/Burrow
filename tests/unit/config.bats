#!/usr/bin/env bats

setup() {
	load ../helpers
	load_libs
	isolate
	ENV_FILE=$BURROW_ENV_FILE
}

write_env() { printf '%s\n' "$@" >"$ENV_FILE"; }

@test "load: parses values, quotes, comments, blank lines and CRLF" {
	secret=$(secret_new notes.example.org)
	write_env "# comment" "" "BURROW_MODE=stealth" "DOMAIN=notes.example.org" \
		"SECRET=$secret" "BLOCKLIST_URLS=\"https://a.org/x https://b.org/y\"" \
		"ACME_EMAIL='me@example.org'" $'PROXY_PORT=8443\r'
	config_load "$ENV_FILE"
	[[ $DOMAIN == notes.example.org ]]
	[[ $BLOCKLIST_URLS == "https://a.org/x https://b.org/y" ]]
	[[ $ACME_EMAIL == me@example.org ]]
	[[ $PROXY_PORT == 8443 ]]
	[[ $HTTP_PORT == 80 ]] # default applied
}

@test "load: does not execute anything" {
	# shellcheck disable=SC2016 # literal $() and backticks are the point
	write_env 'DOMAIN=$(touch '"$BATS_TEST_TMPDIR"'/pwned)' 'BURROW_MODE=`id`'
	config_load "$ENV_FILE"
	[[ ! -e $BATS_TEST_TMPDIR/pwned ]]
	# shellcheck disable=SC2016
	[[ $BURROW_MODE == '`id`' ]]
}

@test "load: ignores (and warns about) unknown keys" {
	write_env "DOMAIN=a.example.org" "PATH=/tmp/evil" "LD_PRELOAD=/tmp/x.so"
	run config_load "$ENV_FILE"
	assert_success
	assert_output --partial "unknown setting PATH"
	config_load "$ENV_FILE" 2>/dev/null
	[[ $PATH != /tmp/evil ]]
}

@test "load: malformed lines are fatal" {
	write_env "DOMAIN a.example.org"
	run config_load "$ENV_FILE"
	assert_failure
	assert_output --partial "expected KEY=value"
}

@test "load: the process environment cannot leak into the config" {
	write_env "DOMAIN=a.example.org"
	export PROXY_PORT=1 METRICS_PORT=2
	config_load "$ENV_FILE"
	[[ $PROXY_PORT == 443 && $METRICS_PORT == 3129 ]]
}

@test "load: missing file explains what to do" {
	run config_load "$BATS_TEST_TMPDIR/nope"
	assert_failure
	assert_output --partial "burrow init"
}

@test "an explicitly empty BLOCKLIST_URLS stays empty" {
	write_env "BLOCKLIST_URLS="
	config_load "$ENV_FILE"
	[[ -z $BLOCKLIST_URLS ]]
	write_env "DOMAIN=a.example.org"
	config_load "$ENV_FILE"
	[[ $BLOCKLIST_URLS == "$DEFAULT_BLOCKLIST_URLS" ]]
}

@test "validate: a fresh stealth config is valid" {
	stealth_config
	run config_validate
	assert_success
}

@test "validate: stealth mode requires a domain" {
	stealth_config
	DOMAIN=''
	run config_validate
	assert_failure
	assert_output --partial "stealth mode needs a domain"
}

@test "validate: simple mode requires a cover domain and an address" {
	config_reset
	BURROW_MODE=simple
	config_set_defaults
	run config_validate
	assert_failure
	assert_output --partial "COVER_DOMAIN"
	assert_output --partial "PUBLIC_IPV4"
}

@test "validate: the secret must encode the fronting host" {
	stealth_config
	SECRET=$(secret_new other.example.org)
	run config_validate
	assert_failure
	assert_output --partial "encodes 'other.example.org'"
}

@test "validate: reports every problem at once" {
	stealth_config
	PROXY_PORT=99999 TIME_SKEW=forever MTG_MEMORY_LIMIT=lots
	run config_validate
	assert_failure
	assert_output --partial PROXY_PORT
	assert_output --partial TIME_SKEW
	assert_output --partial MTG_MEMORY_LIMIT
}

@test "validate: proxy and http ports must differ" {
	stealth_config
	HTTP_PORT=443
	run config_validate
	assert_output --partial "HTTP_PORT: must differ"
}

@test "validate: decoy IP must be a host inside the subnet" {
	stealth_config
	for ip in 10.203.47.0 10.203.47.1 10.203.47.15 10.203.48.10; do
		DECOY_IP=$ip
		run config_validate
		assert_failure
	done
	DECOY_IP=10.203.47.14
	run config_validate
	assert_success
}

@test "validate: local list files must exist" {
	stealth_config
	LOCAL_BLOCKLIST=/nonexistent/list.netset
	run config_validate
	assert_output --partial "not readable"
	printf '203.0.113.0/24\n' >"$BATS_TEST_TMPDIR/list.netset"
	LOCAL_BLOCKLIST=$BATS_TEST_TMPDIR/list.netset
	run config_validate
	assert_success
}

@test "subnet helpers" {
	run subnet_host 10.203.47.0/28 10
	assert_output 10.203.47.10
	run subnet_host 192.168.7.130/25 10
	assert_output 192.168.7.138
	run ip_in_subnet 10.0.0.5 10.0.0.0/29
	assert_success
	run ip_in_subnet 10.0.0.9 10.0.0.0/29
	assert_failure
}

@test "front host and link host follow the mode" {
	stealth_config
	[[ $(config_front_host) == notes.example.org && $(config_link_host) == notes.example.org ]]
	LINK_HOST=203.0.113.7
	[[ $(config_link_host) == 203.0.113.7 ]]
	BURROW_MODE=simple COVER_DOMAIN=www.example.com PUBLIC_IPV4=198.51.100.2 LINK_HOST=''
	[[ $(config_front_host) == www.example.com && $(config_link_host) == 198.51.100.2 ]]
}

@test "write + load round-trips every key, mode 0600" {
	stealth_config
	ACME_EMAIL=me@example.org UPSTREAM_PROXIES="socks5://10.0.0.2:1080 socks5://10.0.0.3:1080"
	declare -A before
	for key in "${CONFIG_KEYS[@]}"; do before[$key]=${!key}; done
	config_write "$ENV_FILE"
	[[ $(stat -c %a "$ENV_FILE") == 600 ]]
	config_load "$ENV_FILE"
	for key in "${CONFIG_KEYS[@]}"; do
		[[ ${!key} == "${before[$key]}" ]] || {
			echo "mismatch: $key"
			return 1
		}
	done
}

@test "set_value replaces one line and keeps the rest" {
	write_env "# keep me" "DOMAIN=a.example.org" "PROXY_PORT=443"
	config_set_value "$ENV_FILE" PROXY_PORT 8443
	run cat "$ENV_FILE"
	assert_output $'# keep me\nDOMAIN=a.example.org\nPROXY_PORT=8443'
	config_set_value "$ENV_FILE" ACME_EMAIL me@example.org
	assert_equal "$(tail -n1 "$ENV_FILE")" "ACME_EMAIL=me@example.org"
	[[ $(stat -c %a "$ENV_FILE") == 600 ]]
}

@test ".env.example documents every setting" {
	for key in "${CONFIG_KEYS[@]}"; do
		grep -q "^#\? \?$key=" "$BURROW_ROOT/.env.example" || {
			echo "missing from .env.example: $key"
			return 1
		}
	done
}

@test "validate: every key is checked in simple mode too" {
	config_reset
	BURROW_MODE=simple COVER_DOMAIN=www.example.com PUBLIC_IPV4=198.51.100.2
	config_set_defaults
	SECRET=$(secret_new www.example.com)
	HTTP_PORT=0 DECOY_IP=nope EDGE_SUBNET6=bad CONCURRENCY=0123
	run config_validate
	assert_failure
	assert_output --partial HTTP_PORT
	assert_output --partial DECOY_IP
	assert_output --partial EDGE_SUBNET6
	assert_output --partial CONCURRENCY
}

@test "redact_userinfo hides SOCKS credentials" {
	run redact_userinfo "socks5://user:pa55@10.0.0.2:1080 socks5://10.0.0.3:1080"
	assert_output "socks5://***@10.0.0.2:1080 socks5://10.0.0.3:1080"
}

@test "validate: IPv6 cannot be combined with a specific BIND_ADDR" {
	stealth_config
	ENABLE_IPV6=true BIND_ADDR=203.0.113.7
	run config_validate
	assert_failure
	assert_output --partial "ENABLE_IPV6=true"
	BIND_ADDR=0.0.0.0
	run config_validate
	assert_success
}

@test "load: simple mode re-derives a DECOY_IP left outside a changed subnet" {
	secret=$(secret_new www.example.com)
	write_env "BURROW_MODE=simple" "COVER_DOMAIN=www.example.com" "PUBLIC_IPV4=198.51.100.2" \
		"SECRET=$secret" "EDGE_SUBNET=10.77.1.0/28" "DECOY_IP=10.203.47.10"
	config_load "$ENV_FILE"
	[[ $DECOY_IP == 10.77.1.10 ]]
	run config_validate
	assert_success
}
