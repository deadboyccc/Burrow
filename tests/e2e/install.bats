#!/usr/bin/env bats
# install.sh for real: fetch the committed code from a local git repository,
# unpack, init, up, smoke and share. Then run it again, which must upgrade in
# place and keep the secret. Host preparation (firewall, sysctl) is skipped
# on purpose: tests never reconfigure the machine they run on.

setup_file() {
	load ../helpers
	have_docker || return 0
	export WORK=$BATS_FILE_TMPDIR
	export REMOTE_DIR=$WORK/opt/burrow
	export BURROW_PROJECT=burrow-e2e-install-$$
	# A throwaway repository with a branch at the commit under test.
	git init -q "$WORK/repo"
	git -C "$WORK/repo" fetch -q "$BURROW_ROOT" HEAD
	git -C "$WORK/repo" branch -q e2e FETCH_HEAD
}

teardown_file() {
	load ../helpers
	have_docker || return 0
	if [[ -x $REMOTE_DIR/burrow ]]; then
		as_root "$REMOTE_DIR/burrow" down --volumes >/dev/null 2>&1 || true
	fi
	if ((EUID != 0)) && sudo -n true 2>/dev/null; then sudo rm -rf -- "$WORK/opt"; fi
}

setup() {
	load ../helpers
	require_docker
	if ((EUID != 0)) && ! sudo -n true 2>/dev/null; then skip "needs root or passwordless sudo"; fi
	unset BURROW_ENV_FILE BURROW_STATE_DIR
}

as_root() { if ((EUID == 0)); then "$@"; else sudo -n env BURROW_PROJECT="$BURROW_PROJECT" "$@"; fi; }

port() { (
	# shellcheck source=/dev/null
	source "$BURROW_ROOT/lib/common.sh"
	free_port
); }

install_burrow() {
	as_root env BURROW_PROJECT="$BURROW_PROJECT" BURROW_REPO="file://$WORK/repo" BURROW_REF=e2e \
		BURROW_DIR="$REMOTE_DIR" BURROW_SKIP_HOST_SETUP=1 "$@" bash "$BURROW_ROOT/install.sh"
}

@test "one command: fetch, configure, start, smoke-test and share" {
	run install_burrow BURROW_DOMAIN=install.burrow.test BURROW_PORT="$(port)" \
		BURROW_INIT_ARGS="--tls internal --bind 127.0.0.1 --http-port $(port) --metrics-port $(port) --ipv4 127.0.0.1 --link-host 127.0.0.1 --no-blocklist --subnet $(random_subnet)"
	assert_success
	assert_output --partial "creating the configuration and a fresh secret"
	assert_output --partial "all 8 checks passed"
	assert_output --partial "tg://proxy?server=127.0.0.1"
	assert_output --partial "Back up $REMOTE_DIR/.env"
	[[ $(as_root stat -c %a "$REMOTE_DIR/.env") == 600 ]]
	[[ -f $REMOTE_DIR/install.sh && ! -e $REMOTE_DIR/.git ]]
}

@test "running it again upgrades in place and keeps the secret" {
	[[ -f $REMOTE_DIR/.env ]] || skip "the first install did not run"
	before=$(as_root grep '^SECRET=' "$REMOTE_DIR/.env")
	run install_burrow BURROW_DOMAIN=install.burrow.test
	assert_success
	assert_output --partial "keeping the existing configuration and secret"
	assert_output --partial "all 8 checks passed"
	[[ $(as_root grep '^SECRET=' "$REMOTE_DIR/.env") == "$before" ]]
}
