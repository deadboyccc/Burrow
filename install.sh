#!/usr/bin/env bash
# burrow one-command installer. Run it ON the server (Debian/Ubuntu), as root.
#
#   Stealth mode (recommended: your own domain, A record pointing at the server):
#     curl -fsSL https://raw.githubusercontent.com/deadboyccc/Burrow/main/install.sh |
#       sudo BURROW_DOMAIN=notes.example.com BURROW_EMAIL=you@example.com bash
#
#   Simple mode (no domain; impersonate a popular site reachable where your users are):
#     curl -fsSL https://raw.githubusercontent.com/deadboyccc/Burrow/main/install.sh |
#       sudo BURROW_COVER_DOMAIN=www.wikipedia.org bash
#
# It installs git/curl if needed, fetches this burrow release, prepares the host
# (Docker, firewall, kernel tuning, time sync, security updates, watchdog), creates
# the secret, starts the proxy, runs the smoke test, and prints the share links and
# a QR code. Re-running it upgrades burrow in place and keeps the existing secret.
#
# Settings (environment variables):
#   BURROW_DOMAIN           stealth mode: your domain (A record -> this server)
#   BURROW_COVER_DOMAIN     simple mode: a popular HTTPS site reachable by your users
#   BURROW_EMAIL            Let's Encrypt account email (optional, stealth mode)
#   BURROW_PORT             public proxy port (default 443)
#   BURROW_LINK_HOST        what share links point at (default: domain, or IP in simple mode)
#   BURROW_ENABLE_IPV6      true: also listen on IPv6
#   BURROW_SSH_PORT         your SSH port, if it can't be detected (ports sshd listens
#                           on are always kept open in the firewall)
#   BURROW_DIR              install directory (default /opt/burrow)
#   BURROW_REF              git tag or branch to install (default: this release)
#   BURROW_REPO             git URL (default: the official repository)
#   BURROW_INIT_ARGS        extra `burrow init` flags, e.g. "--subnet 10.77.1.0/28"
#   BURROW_SKIP_HOST_SETUP  1: leave Docker/firewall/sysctl alone (you manage the host)
#   BURROW_DRY_RUN          1: print every step, change nothing
#
# The whole script is one function called on the last line, so a truncated
# download can never run half of it.

set -Eeuo pipefail

BURROW_INSTALLER_REF=v1.1.0 # the release this installer belongs to

say() { printf '%s\n' "$*" >&2; }
step() { printf '\n\033[1m==> %s\033[0m\n' "$*" >&2; }
die() {
	printf 'error: %s\n' "$*" >&2
	exit 1
}

valid_port() { [[ $1 =~ ^[1-9][0-9]{0,4}$ ]] && (($1 <= 65535)); }

# Removed on exit, however the script ends.
BURROW_SRC=''
trap 'rm -rf -- "${BURROW_SRC:-}"' EXIT

# run CMD...: execute, or only print it with BURROW_DRY_RUN=1.
run() {
	if [[ ${BURROW_DRY_RUN:-0} == 1 ]]; then
		printf '    [dry-run] %s\n' "$*" >&2
	else
		"$@"
	fi
}

main() {
	local domain=${BURROW_DOMAIN:-} cover=${BURROW_COVER_DOMAIN:-} email=${BURROW_EMAIL:-}
	local port=${BURROW_PORT:-443} link_host=${BURROW_LINK_HOST:-} ipv6=${BURROW_ENABLE_IPV6:-false}
	local ssh_port=${BURROW_SSH_PORT:-} dir=${BURROW_DIR:-/opt/burrow}
	local ref=${BURROW_REF:-$BURROW_INSTALLER_REF}
	local repo=${BURROW_REPO:-https://github.com/deadboyccc/Burrow.git}
	local dry=${BURROW_DRY_RUN:-0} skip_host=${BURROW_SKIP_HOST_SETUP:-0}
	local extra_init=() arg
	read -ra extra_init <<<"${BURROW_INIT_ARGS:-}"
	for arg in "${extra_init[@]}"; do
		[[ $arg =~ ^[A-Za-z0-9._:/@,=-]+$ ]] || die "BURROW_INIT_ARGS: unsupported characters in '$arg'"
	done

	# --- check the settings before touching anything -------------------------
	domain=${domain,,} cover=${cover,,} link_host=${link_host,,}
	if [[ -n $domain && -n $cover ]]; then
		die "set BURROW_DOMAIN (stealth mode) or BURROW_COVER_DOMAIN (simple mode), not both"
	fi
	if [[ -z $domain && -z $cover ]]; then
		die "set BURROW_DOMAIN=your.domain (recommended) or BURROW_COVER_DOMAIN=popular.site (no domain).
       Example: curl -fsSL https://raw.githubusercontent.com/deadboyccc/Burrow/main/install.sh | sudo BURROW_DOMAIN=notes.example.com bash"
	fi
	local host_re='^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]([a-z0-9-]{0,61}[a-z0-9])?$'
	[[ -z $domain || $domain =~ $host_re ]] || die "BURROW_DOMAIN is not a valid domain name: $domain"
	[[ -z $cover || $cover =~ $host_re ]] || die "BURROW_COVER_DOMAIN is not a valid domain name: $cover"
	valid_port "$port" || die "BURROW_PORT must be 1-65535"
	[[ -z $ssh_port ]] || valid_port "$ssh_port" || die "BURROW_SSH_PORT must be 1-65535"
	[[ $ipv6 == true || $ipv6 == false ]] || die "BURROW_ENABLE_IPV6 must be true or false"
	[[ $dir =~ ^/[A-Za-z0-9._/-]+$ && $dir != *..* ]] || die "BURROW_DIR must be an absolute path"
	[[ $ref =~ ^[A-Za-z0-9._/-]+$ ]] || die "BURROW_REF is not a valid git ref"
	[[ $repo =~ ^(https://|file://|/)[A-Za-z0-9._/:@-]+$ ]] || die "BURROW_REPO must be an https:// git URL"
	((EUID == 0)) || [[ $dry == 1 ]] || die "run as root, for example: curl -fsSL …/install.sh | sudo BURROW_DOMAIN=… bash"

	local mode=stealth
	[[ -n $cover ]] && mode=simple
	say "burrow installer ($ref): $mode mode, ${domain:-$cover}, port $port, into $dir"

	# --- prerequisites -------------------------------------------------------
	step "prerequisites"
	if ! command -v git >/dev/null 2>&1 || ! command -v curl >/dev/null 2>&1; then
		command -v apt-get >/dev/null 2>&1 || die "git and curl are required (this installer automates Debian/Ubuntu)"
		run apt-get update -qq
		run env DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends git curl ca-certificates
	else
		say "    git and curl are present"
	fi

	# --- fetch burrow --------------------------------------------------------
	# Unpacked over the install directory: .env (the secret), state/ and
	# site.local/ are not part of the release, so they are never touched.
	step "fetching burrow $ref"
	BURROW_SRC=$(mktemp -d)
	run git -c advice.detachedHead=false clone --quiet --depth 1 --branch "$ref" "$repo" "$BURROW_SRC/burrow"
	run install -d -m 0755 "$dir"
	if [[ $dry == 1 ]]; then
		say "    [dry-run] git archive HEAD | tar -x -C $dir"
	else
		git -C "$BURROW_SRC/burrow" archive --format=tar HEAD | tar -x -C "$dir" --no-same-owner
	fi

	# --- host ----------------------------------------------------------------
	local ports=$port
	[[ $mode == stealth ]] && ports=80,$port
	if [[ $skip_host == 1 ]]; then
		step "host preparation skipped (BURROW_SKIP_HOST_SETUP=1)"
	else
		step "preparing the host: Docker, firewall, kernel tuning, time sync, updates, watchdog"
		local host_args=(--dir "$dir" --ports "$ports")
		[[ -n $ssh_port ]] && host_args+=(--ssh-port "$ssh_port")
		run "$dir/scripts/install-host.sh" "${host_args[@]}"
	fi

	# --- configure (first run only) ------------------------------------------
	local burrow=("$dir/burrow")
	if [[ -f $dir/.env ]]; then
		step "keeping the existing configuration and secret ($dir/.env)"
		say "    (change settings later with: $dir/burrow config set KEY VALUE)"
	else
		step "creating the configuration and a fresh secret"
		local init_args=(init --port "$port" --quiet)
		if [[ $mode == stealth ]]; then
			init_args+=(--domain "$domain")
		else
			init_args+=(--mode simple --cover-domain "$cover")
		fi
		[[ -n $email ]] && init_args+=(--email "$email")
		[[ -n $link_host ]] && init_args+=(--link-host "$link_host")
		[[ $ipv6 == true ]] && init_args+=(--enable-ipv6)
		run "${burrow[@]}" "${init_args[@]}" "${extra_init[@]}"
	fi

	# --- start, verify, share ------------------------------------------------
	step "starting burrow"
	run "${burrow[@]}" up
	step "smoke test (real handshakes, a real Telegram round trip, probe resistance)"
	run "${burrow[@]}" smoke || die "burrow is running but failed its smoke test (details above). Diagnose with: $dir/burrow doctor"
	step "share"
	run "${burrow[@]}" share

	say ""
	say "Done. burrow is running and will restart itself (and be watched) after reboots."
	say "  Back up $dir/.env somewhere safe: it holds your secret."
	say "  Manage it with: $dir/burrow status | share | rotate | logs | doctor"
}

main "$@"
