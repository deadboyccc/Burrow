#!/usr/bin/env bats
# scripts/install-host.sh, exercised in a throwaway Debian container in
# --dry-run mode, so no test ever modifies the machine running it.

DEBIAN_IMAGE=python:3.12-slim

setup() {
	load ../helpers
	require_docker
	docker image inspect "$DEBIAN_IMAGE" >/dev/null 2>&1 || docker pull -q "$DEBIAN_IMAGE" >/dev/null
}

in_debian() {
	docker run --rm --network none --memory 128m -v "$BURROW_ROOT:/burrow:ro" "$@"
}

@test "dry run on a bare Debian plans every step" {
	run in_debian "$DEBIAN_IMAGE" bash /burrow/scripts/install-host.sh --dry-run --dir /opt/burrow --ssh-port 2222
	assert_success
	assert_output --partial "download.docker.com"
	assert_output --partial "docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin"
	assert_output --partial "/etc/sysctl.d/99-burrow.conf"
	assert_output --partial "ufw limit 2222/tcp"
	assert_output --partial "ufw allow 80/tcp"
	assert_output --partial "ufw allow 443/tcp"
	assert_output --partial "ufw --force enable"
	assert_output --partial "unattended-upgrades"
	assert_output --partial "systemctl enable --now burrow-watchdog.timer"
	assert_output --partial "host ready"
}

@test "SSH is allowed before the firewall is enabled" {
	run in_debian "$DEBIAN_IMAGE" bash /burrow/scripts/install-host.sh --dry-run --ssh-port 2222
	limit=$(grep -n 'ufw limit 2222/tcp' <<<"$output" | cut -d: -f1)
	enable=$(grep -n 'ufw --force enable' <<<"$output" | cut -d: -f1)
	((limit < enable))
}

@test "steps can be switched off, custom ports respected" {
	run in_debian "$DEBIAN_IMAGE" bash /burrow/scripts/install-host.sh --dry-run --ssh-port 22 \
		--no-docker --no-sysctl --no-upgrades --no-watchdog --ports 80,8443
	assert_success
	refute_output --partial "download.docker.com"
	refute_output --partial "99-burrow.conf"
	refute_output --partial "burrow-watchdog"
	assert_output --partial "ufw allow 8443/tcp"
}

@test "SSH lockout guard: no known SSH port means no firewall" {
	run in_debian "$DEBIAN_IMAGE" bash /burrow/scripts/install-host.sh --dry-run --no-docker
	assert_success
	assert_output --partial "NOT enabling the firewall"
	refute_output --partial "ufw --force enable"
}

@test "SSH lockout guard: the session port and the explicit port are both allowed" {
	run in_debian -e SSH_CONNECTION="198.51.100.9 50000 203.0.113.7 2200" "$DEBIAN_IMAGE" \
		bash /burrow/scripts/install-host.sh --dry-run --no-docker --ssh-port 22
	assert_output --partial "ufw limit 22/tcp"
	assert_output --partial "ufw limit 2200/tcp"
}

@test "Docker daemon config is written before the packages start dockerd" {
	run in_debian "$DEBIAN_IMAGE" bash /burrow/scripts/install-host.sh --dry-run --ssh-port 22
	daemon=$(grep -n 'daemon.json' <<<"$output" | head -n1 | cut -d: -f1)
	packages=$(grep -n 'docker-ce docker-ce-cli' <<<"$output" | cut -d: -f1)
	((daemon < packages))
	assert_output --partial "52burrow-docker-upgrades"
}

@test "refuses to run without root (outside --dry-run) and validates input" {
	run in_debian --user 65534:65534 "$DEBIAN_IMAGE" bash /burrow/scripts/install-host.sh
	assert_failure
	assert_output --partial "run as root"
	run in_debian "$DEBIAN_IMAGE" bash /burrow/scripts/install-host.sh --dry-run --ssh-port abc
	assert_failure
	run in_debian "$DEBIAN_IMAGE" bash /burrow/scripts/install-host.sh --dry-run --ports '80;reboot'
	assert_failure
	run in_debian "$DEBIAN_IMAGE" bash /burrow/scripts/install-host.sh --dry-run --dir '/opt/a b|c'
	assert_failure
}

@test "unsupported distributions without Docker get a clear message" {
	printf 'ID=arch\nPRETTY_NAME="Arch Linux"\n' >"$BATS_TEST_TMPDIR/os-release"
	run in_debian -v "$BATS_TEST_TMPDIR/os-release:/os-release:ro" -e OS_RELEASE=/os-release \
		"$DEBIAN_IMAGE" bash /burrow/scripts/install-host.sh --dry-run
	assert_failure
	assert_output --partial "not Debian/Ubuntu"
}

@test "systemd units are templated with the install directory" {
	grep -q '^ExecStart=@BURROW_DIR@/burrow watchdog$' "$BURROW_ROOT/deploy/systemd/burrow-watchdog.service"
	grep -q '^OnUnitActiveSec=5min$' "$BURROW_ROOT/deploy/systemd/burrow-watchdog.timer"
}

@test "sysctl tuning enables BBR and fq" {
	grep -q '^net.ipv4.tcp_congestion_control = bbr$' "$BURROW_ROOT/deploy/sysctl/99-burrow.conf"
	grep -q '^net.core.default_qdisc = fq$' "$BURROW_ROOT/deploy/sysctl/99-burrow.conf"
}
