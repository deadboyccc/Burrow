# shellcheck shell=bash
# Pure validators: each returns 0 (valid) or 1, prints nothing.
# Strict on purpose: every value ends up in TOML, a Caddyfile or a compose
# file, so anything outside a small, known alphabet is rejected up front
# instead of being escaped later.

is_bool() { [[ $1 == true || $1 == false ]]; }

is_uint() { [[ $1 =~ ^[0-9]+$ ]]; }

# A positive integer without leading zeros (valid in TOML).
is_count() { [[ $1 =~ ^[1-9][0-9]{0,8}$ ]]; }

is_port() { [[ $1 =~ ^[0-9]{1,5}$ ]] && (($1 >= 1 && $1 <= 65535)); }

# Lowercase LDH hostname with at least one dot (an FQDN). IDNs must be
# given in punycode (xn--...).
is_hostname() {
	local h=$1 label
	[[ ${#h} -le 253 && $h == *.* && $h =~ ^[a-z0-9.-]+$ ]] || return 1
	[[ $h != .* && $h != *. && $h != *..* ]] || return 1
	local IFS=.
	for label in $h; do
		[[ ${#label} -ge 1 && ${#label} -le 63 && $label != -* && $label != *- ]] || return 1
	done
	# The last label (TLD) must not be all digits, or this is an IP.
	[[ ! ${h##*.} =~ ^[0-9]+$ ]]
}

is_ipv4() {
	local ip=$1 octet
	[[ $ip =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] || return 1
	local IFS=.
	for octet in $ip; do
		[[ $octet == 0 || $octet != 0* ]] || return 1 # no leading zeros
		((octet <= 255)) || return 1
	done
}

# Eight 1-4 digit hex groups, or fewer around a single "::". No zone ids and
# no embedded IPv4.
is_ipv6() {
	local ip=$1 head tail groups=() part group n=0
	[[ $ip =~ ^[0-9a-fA-F:]+$ && ${#ip} -le 39 ]] || return 1
	if [[ $ip == *::* ]]; then
		head=${ip%%::*} tail=${ip#*::}
		[[ $tail != *::* ]] || return 1
	else
		head=$ip tail=''
	fi
	for part in "$head" "$tail"; do
		[[ -z $part ]] && continue
		IFS=: read -ra groups <<<"$part"
		[[ $part != :* && $part != *: ]] || return 1
		for group in "${groups[@]}"; do
			[[ $group =~ ^[0-9a-fA-F]{1,4}$ ]] || return 1
			n=$((n + 1))
		done
	done
	if [[ $ip == *::* ]]; then ((n <= 7)); else ((n == 8)); fi
}

is_ip() { is_ipv4 "$1" || is_ipv6 "$1"; }

is_bind_addr() { is_ipv4 "$1"; }

is_cidr4() {
	[[ $1 == */* ]] || return 1
	local ip=${1%/*} bits=${1#*/}
	is_ipv4 "$ip" && [[ $bits =~ ^[0-9]{1,2}$ ]] && ((bits <= 32))
}

is_cidr6() {
	[[ $1 == */* ]] || return 1
	local ip=${1%/*} bits=${1#*/}
	is_ipv6 "$ip" && [[ $bits =~ ^[0-9]{1,3}$ ]] && ((bits <= 128))
}

# Go time.ParseDuration subset: 500ms, 5s, 1m30s, 24h.
is_duration() { [[ $1 =~ ^([0-9]+(ms|s|m|h))+$ ]]; }

# mtg byte sizes: 512kib, 1mib, 2gib.
is_bytes() { [[ ${1,,} =~ ^[0-9]+(b|kib|mib|gib)$ ]]; }

# Docker memory limits: 256m, 1g.
is_mem() { [[ $1 =~ ^[0-9]+[kmg]$ ]]; }

is_email() { [[ $1 =~ ^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$ ]]; }

# https URL without characters that would need escaping in TOML/Caddyfile.
is_https_url() { [[ $1 =~ ^https://[A-Za-z0-9.-]+(:[0-9]+)?(/[A-Za-z0-9._~%/+=-]*)?$ ]]; }

is_http_url() { [[ $1 =~ ^https?://[A-Za-z0-9.-]+(:[0-9]+)?(/[A-Za-z0-9._~%/+=-]*)?$ ]]; }

# socks5://[user:pass@]host:port. Credentials limited to a safe alphabet.
is_socks5_url() { [[ $1 =~ ^socks5://([A-Za-z0-9._~%-]+(:[A-Za-z0-9._~%-]*)?@)?[A-Za-z0-9.-]+:[0-9]{1,5}$ ]]; }

# mtg DNS setting: https://, tls://, udp:// or a bare IP.
is_dns_uri() {
	[[ $1 =~ ^(https|tls)://[A-Za-z0-9.-]+(:[0-9]+)?(/[A-Za-z0-9._/-]*)?$ ]] ||
		[[ $1 =~ ^(udp://)?[0-9.]+(:[0-9]+)?$ ]]
}

is_prefer_ip() {
	case $1 in prefer-ipv4 | prefer-ipv6 | only-ipv4 | only-ipv6) return 0 ;; esac
	return 1
}

is_mode() { [[ $1 == stealth || $1 == simple ]]; }

is_tls_mode() { [[ $1 == acme || $1 == internal ]]; }

# Absolute host path made of safe characters (it is copied, never interpolated).
is_abs_path() { [[ $1 =~ ^/[A-Za-z0-9._/-]+$ && $1 != *..* ]]; }
