#!/usr/bin/env bats
# IP block and allow lists, applied by the real mtg.

setup_file() {
	load ../helpers
	have_docker || return 0
	export BURROW_ENV_FILE=$BATS_FILE_TMPDIR/.env BURROW_STATE_DIR=$BATS_FILE_TMPDIR/state
	export BURROW_PROJECT=burrow-e2e-def-$$
	export LISTS=$BATS_FILE_TMPDIR/lists
	mkdir -p "$LISTS"
	printf '# everyone\n0.0.0.0/0\n' >"$LISTS/everyone.netset"
	printf '# documentation range only\n203.0.113.0/24\n' >"$LISTS/nobody.netset"
	burrow init --domain def.burrow.test --tls internal --bind 127.0.0.1 --port "$(port)" \
		--http-port "$(port)" --metrics-port "$(port)" --ipv4 127.0.0.1 --no-blocklist \
		--subnet "$(random_subnet)" --quiet
}

teardown_file() {
	load ../helpers
	have_docker || return 0
	burrow down --volumes >/dev/null 2>&1 || true
}

setup() {
	load ../helpers
	require_docker
}

port() {
	(
		# shellcheck source=/dev/null
		source "$BURROW_ROOT/lib/common.sh"
		free_port
	)
}

# Probe from inside the stack network; lists load asynchronously, so retry.
probe_expect() {
	(
		# shellcheck source=/dev/null
		for lib in common validate secret links config render compose; do source "$BURROW_ROOT/lib/$lib.sh"; done
		ENV_FILE=$BURROW_ENV_FILE STATE_DIR=$BURROW_STATE_DIR
		config_load "$ENV_FILE"
		tools_in_stack probe --host mtg --port 3128 --expect "$1" --retries 20 --retry-delay 1 --timeout 3
	)
}

@test "a blocklisted client is dropped without a response" {
	burrow config set LOCAL_BLOCKLIST "$LISTS/everyone.netset" >/dev/null
	burrow up --no-wait
	run probe_expect closed
	assert_success
	assert_output --partial "closed"
}

@test "with an allowlist, everyone else is dropped" {
	burrow config set LOCAL_BLOCKLIST "" LOCAL_ALLOWLIST "$LISTS/nobody.netset" >/dev/null
	burrow up --no-wait
	run probe_expect closed
	assert_success
}

@test "an allowlisted client gets through" {
	burrow config set LOCAL_ALLOWLIST "$LISTS/everyone.netset" >/dev/null
	burrow up --no-wait
	run probe_expect proxy
	assert_success
}

@test "a client outside the tolerated clock skew is refused" {
	burrow config set TIME_SKEW 2s >/dev/null
	burrow up --no-wait
	run probe_expect proxy
	assert_success
	(
		# shellcheck source=/dev/null
		for lib in common validate secret links config render compose; do source "$BURROW_ROOT/lib/$lib.sh"; done
		ENV_FILE=$BURROW_ENV_FILE STATE_DIR=$BURROW_STATE_DIR
		config_load "$ENV_FILE"
		tools_in_stack probe --host mtg --port 3128 --time-offset 30 --expect fronted
	)
}
