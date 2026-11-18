#!/usr/bin/env bats
# `burrow deploy` end to end. A fake ssh (tests/e2e/fake-ssh) runs the "remote"
# side on this machine, in its own install directory, so the real upload,
# init, up, smoke and link steps all execute.

setup_file() {
	load ../helpers
	have_docker || return 0
	export REMOTE_DIR=$BATS_FILE_TMPDIR/server/opt/burrow
	export BURROW_PROJECT=burrow-e2e-deploy-$$
	export FAKE_BIN=$BATS_FILE_TMPDIR/bin
	mkdir -p "$FAKE_BIN"
	ln -s "$BURROW_ROOT/tests/e2e/fake-ssh" "$FAKE_BIN/ssh"
}

teardown_file() {
	load ../helpers
	have_docker || return 0
	if [[ -x $REMOTE_DIR/burrow ]]; then
		as_remote "$REMOTE_DIR/burrow" down --volumes >/dev/null 2>&1 || true
	fi
	if ((EUID != 0)) && sudo -n true 2>/dev/null; then sudo rm -rf -- "$BATS_FILE_TMPDIR/server"; fi
}

setup() {
	load ../helpers
	require_docker
	unset BURROW_ENV_FILE BURROW_STATE_DIR # the "server" uses its own install dir
}

# Matches deploy: commands run as root (directly, or via sudo, which drops BURROW_PROJECT).
as_remote() { if ((EUID == 0)); then "$@"; else sudo -n "$@"; fi; }

port() { (
	# shellcheck source=/dev/null
	source "$BURROW_ROOT/lib/common.sh"
	free_port
); }

deploy() {
	PATH=$FAKE_BIN:$PATH burrow deploy root@server.test --dir "$REMOTE_DIR" --no-host-setup "$@"
}

@test "first deploy: uploads, initialises on the server, starts, smoke-tests both ends" {
	if ((EUID != 0)) && ! sudo -n true 2>/dev/null; then skip "needs root or passwordless sudo"; fi
	run deploy --domain deploy.burrow.test --tls internal --bind 127.0.0.1 --port "$(port)" \
		--http-port "$(port)" --metrics-port "$(port)" --ipv4 127.0.0.1 --link-host 127.0.0.1 \
		--no-blocklist --subnet "$(random_subnet)"
	assert_success
	assert_output --partial "initialising"
	assert_output --partial "all 8 checks passed"
	assert_output --partial "testing from this machine"
	refute_output --partial "passes locally but not from here"
	assert_line --regexp '^tg://proxy\?server=127\.0\.0\.1&port=[0-9]+&secret=ee[0-9a-f]+$'
	[[ -f $REMOTE_DIR/.env && -x $REMOTE_DIR/burrow && -f $REMOTE_DIR/tools/Dockerfile ]]
	[[ ! -e $REMOTE_DIR/tests/.deps && ! -e $REMOTE_DIR/.git ]]
	[[ $(as_remote stat -c %a "$REMOTE_DIR/.env") == 600 ]]
}

@test "re-deploy upgrades the code and keeps the server's secret" {
	[[ -f $REMOTE_DIR/.env ]] || skip "first deploy did not run"
	before=$(as_remote grep '^SECRET=' "$REMOTE_DIR/.env")
	run deploy --domain ignored.example.org
	assert_success
	assert_output --partial "keeping the existing configuration"
	[[ $(as_remote grep '^SECRET=' "$REMOTE_DIR/.env") == "$before" ]]
}
