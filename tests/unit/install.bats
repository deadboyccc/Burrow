#!/usr/bin/env bats
# install.sh: the one-command server installer. These cases all stop at input
# validation, before the installer does anything.

setup() {
	load ../helpers
	export BURROW_DRY_RUN=1
}

installer() { bash "$BURROW_ROOT/install.sh"; }

@test "installs the release it ships with" {
	version=$("$BURROW_ROOT/burrow" version | cut -d' ' -f2)
	grep -qx "BURROW_INSTALLER_REF=v$version # the release this installer belongs to" "$BURROW_ROOT/install.sh"
}

@test "needs a domain or a cover domain, not both" {
	run installer
	assert_failure
	assert_output --partial "BURROW_DOMAIN"
	BURROW_DOMAIN=notes.example.org BURROW_COVER_DOMAIN=www.example.com run installer
	assert_failure
	assert_output --partial "not both"
}

@test "rejects malformed settings before doing anything" {
	BURROW_DOMAIN='notes.example.org;id' run installer
	assert_failure
	BURROW_DOMAIN=notes.example.org BURROW_PORT=70000 run installer
	assert_failure
	BURROW_DOMAIN=notes.example.org BURROW_SSH_PORT=x run installer
	assert_failure
	BURROW_DOMAIN=notes.example.org BURROW_DIR=relative run installer
	assert_failure
	# shellcheck disable=SC2016 # a literal $(...) is the attack being tested
	BURROW_DOMAIN=notes.example.org BURROW_INIT_ARGS='--subnet $(id)' run installer
	assert_failure
	assert_output --partial "unsupported characters"
	BURROW_DOMAIN=notes.example.org BURROW_ENABLE_IPV6=yes run installer
	assert_failure
}

@test "refuses to run for real without root" {
	((EUID != 0)) || skip "running as root"
	BURROW_DRY_RUN=0 BURROW_DOMAIN=notes.example.org run installer
	assert_failure
	assert_output --partial "run as root"
}
