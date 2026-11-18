#!/usr/bin/env bash
# Prepare a fresh Debian/Ubuntu server for burrow. Idempotent: safe to re-run.
#
#   sudo scripts/install-host.sh [--dir /opt/burrow] [--ssh-port N] [--ports 80,443]
#                                [--no-docker] [--no-firewall] [--no-sysctl]
#                                [--no-upgrades] [--no-watchdog] [--dry-run]
#
# What it does, and why:
#   docker    Docker Engine + Compose plugin from Docker's signed apt repository
#   time      NTP sync: FakeTLS refuses clients when clocks disagree by > 5s
#   sysctl    BBR congestion control, fq qdisc, bigger queues and buffers
#   firewall  ufw: deny inbound except SSH (rate-limited), HTTP and HTTPS.
#             SSH stays open on --ssh-port AND every port sshd listens on.
#   upgrades  unattended security updates
#   watchdog  systemd timer: probe the proxy every 5 minutes, restart if stuck
set -Eeuo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
DIR=$ROOT
SSH_PORT='' # explicit --ssh-port
PORTS=80,443
DO_DOCKER=1 DO_FIREWALL=1 DO_SYSCTL=1 DO_UPGRADES=1 DO_WATCHDOG=1 DRY_RUN=0
OS_RELEASE=${OS_RELEASE:-/etc/os-release}

log() { printf '==> %s\n' "$*" >&2; }
note() { printf '    %s\n' "$*" >&2; }
die() {
	printf 'error: %s\n' "$*" >&2
	exit 1
}

# run CMD...: execute, or only print it with --dry-run.
run() {
	if ((DRY_RUN)); then
		printf '    [dry-run] %s\n' "$*" >&2
	else
		"$@"
	fi
}

# install_file SRC DEST MODE: copy (or print) a file.
install_file() {
	if ((DRY_RUN)); then
		printf '    [dry-run] install -m %s %s %s\n' "$3" "$1" "$2" >&2
	else
		install -D -m "$3" "$1" "$2"
	fi
}

while (($#)); do
	case $1 in
	--dir) DIR=$2 && shift ;;
	--ssh-port) SSH_PORT=$2 && shift ;;
	--ports) PORTS=$2 && shift ;;
	--no-docker) DO_DOCKER=0 ;;
	--no-firewall) DO_FIREWALL=0 ;;
	--no-sysctl) DO_SYSCTL=0 ;;
	--no-upgrades) DO_UPGRADES=0 ;;
	--no-watchdog) DO_WATCHDOG=0 ;;
	--dry-run) DRY_RUN=1 ;;
	-h | --help)
		sed -n '2,15p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
		exit 0
		;;
	*) die "unknown option: $1" ;;
	esac
	shift
done

[[ -z $SSH_PORT || $SSH_PORT =~ ^[0-9]{1,5}$ ]] || die "--ssh-port must be a number"
[[ $PORTS =~ ^[0-9]{1,5}(,[0-9]{1,5})*$ ]] || die "--ports must look like 80,443"
# It is written into a systemd unit and a sed expression.
[[ $DIR =~ ^/[A-Za-z0-9._/-]+$ && $DIR != *..* ]] || die "--dir must be an absolute path of letters, digits, . _ - and /"
((DRY_RUN)) || ((EUID == 0)) || die "run as root (sudo $0 $*)"

# shellcheck source=/dev/null
[[ -r $OS_RELEASE ]] && source "$OS_RELEASE"
DISTRO=${ID:-unknown}
CODENAME=${VERSION_CODENAME:-}
case $DISTRO in
debian | ubuntu) APT=1 ;;
*)
	APT=0
	if [[ ${ID_LIKE:-} == *debian* || ${ID_LIKE:-} == *ubuntu* ]]; then
		APT=1
		if [[ ${ID_LIKE} == *ubuntu* ]]; then DISTRO=ubuntu; else DISTRO=debian; fi
		CODENAME=${UBUNTU_CODENAME:-$CODENAME}
	fi
	;;
esac
# Every port SSH may be reachable on: the explicit --ssh-port (possibly a NAT
# forward), the port of this very session (if sudo kept SSH_CONNECTION), and
# whatever sshd is configured for. Allowing all of them keeps a non-default
# or forwarded SSH port from being firewalled off.
ssh_ports() {
	{
		[[ -n $SSH_PORT ]] && echo "$SSH_PORT"
		[[ -n ${SSH_CONNECTION:-} ]] && awk '{print $4}' <<<"$SSH_CONNECTION"
		if command -v sshd >/dev/null 2>&1; then sshd -T 2>/dev/null | awk '$1 == "port" {print $2}'; fi
		if command -v ss >/dev/null 2>&1; then
			ss -Hltnp 2>/dev/null | awk '/"sshd"/ {n = split($4, a, ":"); print a[n]}'
		fi
	} | grep -E '^[0-9]{1,5}$' | sort -un | paste -sd, - || true
}
SSH_PORTS=$(ssh_ports)

log "host: ${PRETTY_NAME:-$DISTRO} (apt: $([[ $APT == 1 ]] && echo yes || echo no)), ssh port(s) ${SSH_PORTS:-unknown}, burrow in $DIR"

APT_UPDATED=0
apt_install() {
	if ((APT_UPDATED == 0)); then
		run apt-get update -qq
		APT_UPDATED=1
	fi
	run env DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends "$@"
}

# --- Docker ------------------------------------------------------------------
install_docker() {
	if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
		note "Docker $(docker version --format '{{.Server.Version}}' 2>/dev/null || echo '?') with Compose is already installed"
		return 0
	fi
	((APT)) || die "Docker is missing and this is not Debian/Ubuntu. Install Docker Engine + Compose v2, then re-run with --no-docker."
	[[ -n $CODENAME ]] || die "cannot determine the distribution codename from $OS_RELEASE"
	log "installing Docker Engine from download.docker.com ($DISTRO $CODENAME)"
	apt_install ca-certificates curl
	# Before the packages: dockerd starts as soon as it is installed, and only
	# reads daemon.json at start.
	configure_docker_daemon
	run install -m 0755 -d /etc/apt/keyrings
	run curl -fsSL "https://download.docker.com/linux/$DISTRO/gpg" -o /etc/apt/keyrings/docker.asc
	run chmod a+r /etc/apt/keyrings/docker.asc
	local arch
	arch=$(dpkg --print-architecture 2>/dev/null || echo amd64)
	if ((DRY_RUN)); then
		note "[dry-run] write /etc/apt/sources.list.d/docker.sources ($DISTRO $CODENAME $arch)"
	else
		cat >/etc/apt/sources.list.d/docker.sources <<EOF
Types: deb
URIs: https://download.docker.com/linux/$DISTRO
Suites: $CODENAME
Components: stable
Architectures: $arch
Signed-By: /etc/apt/keyrings/docker.asc
EOF
	fi
	APT_UPDATED=0 # the new repository needs a fresh package list
	apt_install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
	run systemctl enable --now docker
}

# live-restore keeps containers running while dockerd restarts or upgrades.
configure_docker_daemon() {
	if [[ -e /etc/docker/daemon.json ]]; then
		note "keeping the existing /etc/docker/daemon.json (consider \"live-restore\": true)"
		return 0
	fi
	if ((DRY_RUN)); then
		note "[dry-run] write /etc/docker/daemon.json {live-restore, local log driver}"
		return 0
	fi
	install -d -m 0755 /etc/docker
	cat >/etc/docker/daemon.json <<'EOF'
{
  "live-restore": true,
  "log-driver": "local",
  "log-opts": { "max-size": "10m", "max-file": "3" }
}
EOF
}

# --- Time --------------------------------------------------------------------
setup_time() {
	log "time synchronisation"
	if command -v chronyc >/dev/null 2>&1 || systemctl is-active --quiet chrony 2>/dev/null; then
		note "chrony is installed"
		return 0
	fi
	if ((APT)) && ! systemctl list-unit-files systemd-timesyncd.service >/dev/null 2>&1; then
		apt_install systemd-timesyncd
	fi
	if command -v timedatectl >/dev/null 2>&1; then
		run timedatectl set-ntp true
	else
		note "no timedatectl: make sure NTP is running"
	fi
}

# --- Kernel tuning -----------------------------------------------------------
setup_sysctl() {
	log "kernel network tuning (BBR, fq, larger queues)"
	if ((DRY_RUN)) || modprobe tcp_bbr 2>/dev/null || grep -qw bbr /proc/sys/net/ipv4/tcp_available_congestion_control 2>/dev/null; then
		install_file "$ROOT/deploy/sysctl/99-burrow.conf" /etc/sysctl.d/99-burrow.conf 0644
		install_file "$ROOT/deploy/sysctl/modules-load-burrow.conf" /etc/modules-load.d/burrow.conf 0644
		((DRY_RUN)) || modprobe nf_conntrack 2>/dev/null || true
		# Some keys are read-only in containers (LXC/OpenVZ); that must not stop
		# the firewall and the rest of the setup.
		run sysctl --quiet --system || note "some kernel settings could not be applied (normal in containers); continuing"
	else
		note "this kernel has no BBR module; skipping (common inside OpenVZ/LXC containers)"
	fi
}

# --- Firewall ----------------------------------------------------------------
setup_firewall() {
	if [[ -z $SSH_PORTS ]]; then
		note "could not determine the SSH port: NOT enabling the firewall (that could lock you out)."
		note "Re-run with --ssh-port N, or allow TCP ${PORTS} and your SSH port yourself."
		return 0
	fi
	log "firewall (ufw): allow SSH ${SSH_PORTS//,/, } (rate-limited) and ${PORTS//,/, }; deny other inbound"
	if ! command -v ufw >/dev/null 2>&1; then
		((APT)) || {
			note "ufw is not available; configure your firewall to allow TCP $SSH_PORT,$PORTS"
			return 0
		}
		apt_install ufw
	fi
	run ufw default deny incoming
	run ufw default allow outgoing
	# Allow SSH *before* enabling, so the current session survives.
	local port
	for port in ${SSH_PORTS//,/ }; do
		run ufw limit "$port/tcp" comment 'ssh'
	done
	for port in ${PORTS//,/ }; do
		run ufw allow "$port/tcp" comment 'burrow'
	done
	run ufw --force enable
	note "Docker publishes ports through its own iptables rules, before ufw sees"
	note "them: burrow publishes only $PORTS publicly; metrics stay on 127.0.0.1."
}

# --- Unattended upgrades -----------------------------------------------------
setup_upgrades() {
	((APT)) || return 0
	log "unattended security upgrades"
	apt_install unattended-upgrades
	if ((DRY_RUN)); then
		note "[dry-run] write /etc/apt/apt.conf.d/20auto-upgrades and 52burrow-docker-upgrades"
	else
		cat >/etc/apt/apt.conf.d/20auto-upgrades <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
EOF
		# Docker's repository is not in the default allowed origins, but runc and
		# containerd fixes are exactly the security updates worth having.
		# live-restore keeps containers running while dockerd restarts.
		cat >/etc/apt/apt.conf.d/52burrow-docker-upgrades <<'EOF'
Unattended-Upgrade::Origins-Pattern { "origin=Docker"; };
EOF
	fi
}

# --- Watchdog ----------------------------------------------------------------
setup_watchdog() {
	if ! command -v systemctl >/dev/null 2>&1 && ((DRY_RUN == 0)); then
		note "no systemd: skipping the watchdog timer"
		return 0
	fi
	log "watchdog timer (probes the proxy every 5 minutes)"
	local unit tmp
	tmp=$(mktemp -d)
	for unit in burrow-watchdog.service burrow-watchdog.timer; do
		sed "s|@BURROW_DIR@|$DIR|g" "$ROOT/deploy/systemd/$unit" >"$tmp/$unit"
		install_file "$tmp/$unit" "/etc/systemd/system/$unit" 0644
	done
	rm -rf -- "$tmp"
	run systemctl daemon-reload
	run systemctl enable --now burrow-watchdog.timer
}

((DO_DOCKER)) && install_docker
setup_time
((DO_SYSCTL)) && setup_sysctl
((DO_FIREWALL)) && setup_firewall
((DO_UPGRADES)) && setup_upgrades
((DO_WATCHDOG)) && setup_watchdog
log "host ready"
