# shellcheck shell=bash
# shellcheck disable=SC2034 # settings are globals consumed by render.sh and the CLI
# The user's configuration (.env): strict parsing, defaults, validation, writing.
#
# .env is read as data and never `source`d, so a malformed or hostile file
# cannot execute code. Only the keys listed below are accepted.

CONFIG_KEYS=(
	BURROW_MODE DOMAIN COVER_DOMAIN SECRET PUBLIC_IPV4 PUBLIC_IPV6 LINK_HOST
	BIND_ADDR PROXY_PORT HTTP_PORT METRICS_PORT ENABLE_IPV6 EDGE_SUBNET DECOY_IP EDGE_SUBNET6
	TLS_MODE ACME_EMAIL ACME_CA
	DNS_RESOLVER PREFER_IP UPSTREAM_PROXIES
	TIME_SKEW ANTI_REPLAY_SIZE BLOCKLIST_ENABLED BLOCKLIST_URLS LOCAL_BLOCKLIST
	ALLOWLIST_URLS LOCAL_ALLOWLIST DOPPELGANGER_URLS
	CONCURRENCY IDLE_TIMEOUT MTG_MEMORY_LIMIT DECOY_MEMORY_LIMIT
	LOGGING DEBUG
)

DEFAULT_BLOCKLIST_URLS="https://iplists.firehol.org/files/firehol_abusers_1d.netset https://iplists.firehol.org/files/spamhaus_drop.netset"

config_reset() {
	local key
	for key in "${CONFIG_KEYS[@]}"; do
		unset "$key"
	done
}

config_set_defaults() {
	: "${BURROW_MODE:=stealth}"
	: "${DOMAIN:=}" "${COVER_DOMAIN:=}" "${SECRET:=}"
	: "${PUBLIC_IPV4:=}" "${PUBLIC_IPV6:=}" "${LINK_HOST:=}"
	: "${BIND_ADDR:=0.0.0.0}"
	: "${PROXY_PORT:=443}"
	: "${HTTP_PORT:=80}"
	: "${METRICS_PORT:=3129}"
	: "${ENABLE_IPV6:=false}"
	: "${EDGE_SUBNET:=10.203.47.0/28}"
	: "${DECOY_IP:=10.203.47.10}"
	: "${EDGE_SUBNET6:=fd42:7572:726f:77::/64}"
	: "${TLS_MODE:=acme}"
	: "${ACME_EMAIL:=}" "${ACME_CA:=}"
	: "${DNS_RESOLVER:=https://1.1.1.1}"
	: "${PREFER_IP:=prefer-ipv4}"
	: "${UPSTREAM_PROXIES:=}"
	: "${TIME_SKEW:=5s}"
	: "${ANTI_REPLAY_SIZE:=1mib}"
	: "${BLOCKLIST_ENABLED:=true}"
	if [[ -z ${BLOCKLIST_URLS+set} ]]; then BLOCKLIST_URLS=$DEFAULT_BLOCKLIST_URLS; fi
	: "${LOCAL_BLOCKLIST:=}" "${ALLOWLIST_URLS:=}" "${LOCAL_ALLOWLIST:=}" "${DOPPELGANGER_URLS:=}"
	: "${CONCURRENCY:=8192}"
	: "${IDLE_TIMEOUT:=5m}"
	: "${MTG_MEMORY_LIMIT:=512m}"
	: "${DECOY_MEMORY_LIMIT:=256m}"
	: "${LOGGING:=on}"
	: "${DEBUG:=false}"
}

config_is_known_key() {
	local key
	for key in "${CONFIG_KEYS[@]}"; do
		[[ $key == "$1" ]] && return 0
	done
	return 1
}

# config_load FILE: reset, parse KEY=value lines, apply defaults.
config_load() {
	local file=$1 line key value n=0
	[[ -f $file ]] || die "no configuration at $file. Create one with: ./burrow init --domain proxy.example.com"
	config_reset
	while IFS= read -r line || [[ -n $line ]]; do
		n=$((n + 1))
		line=${line%$'\r'}
		[[ $line =~ ^[[:space:]]*(#|$) ]] && continue
		[[ $line =~ ^([A-Z][A-Z0-9_]*)=(.*)$ ]] || die "$file:$n: expected KEY=value, got: $line"
		key=${BASH_REMATCH[1]} value=${BASH_REMATCH[2]}
		if [[ $value =~ ^\"(.*)\"$ || $value =~ ^\'(.*)\'$ ]]; then
			value=${BASH_REMATCH[1]}
		fi
		if ! config_is_known_key "$key"; then
			warn "$file:$n: unknown setting $key (ignored)"
			continue
		fi
		printf -v "$key" '%s' "$value"
	done <"$file"
	config_set_defaults
}

# The hostname clients put in SNI, which is also encoded in the secret.
config_front_host() {
	if [[ $BURROW_MODE == stealth ]]; then printf '%s\n' "$DOMAIN"; else printf '%s\n' "$COVER_DOMAIN"; fi
}

# What goes into share links as "server".
config_link_host() {
	if [[ -n $LINK_HOST ]]; then
		printf '%s\n' "$LINK_HOST"
	elif [[ $BURROW_MODE == stealth ]]; then
		printf '%s\n' "$DOMAIN"
	else
		printf '%s\n' "$PUBLIC_IPV4"
	fi
}

ipv4_to_int() {
	local a b c d
	IFS=. read -r a b c d <<<"$1"
	printf '%d\n' $(((a << 24) | (b << 16) | (c << 8) | d))
}

int_to_ipv4() {
	printf '%d.%d.%d.%d\n' $((($1 >> 24) & 255)) $((($1 >> 16) & 255)) $((($1 >> 8) & 255)) $(($1 & 255))
}

# subnet_host CIDR N: the Nth address of the network (N=10 -> x.x.x.10 for a /24).
subnet_host() {
	local net bits mask
	net=$(ipv4_to_int "${1%/*}")
	bits=${1#*/}
	mask=$(((0xFFFFFFFF << (32 - bits)) & 0xFFFFFFFF))
	int_to_ipv4 $(((net & mask) + $2))
}

# ip_in_subnet IP CIDR: true if IP is a usable host address in CIDR and is
# not the first host (Docker hands that to the bridge gateway).
ip_in_subnet() {
	local ip net bits mask
	ip=$(ipv4_to_int "$1")
	net=$(ipv4_to_int "${2%/*}")
	bits=${2#*/}
	((bits >= 1 && bits <= 30)) || return 1
	mask=$(((0xFFFFFFFF << (32 - bits)) & 0xFFFFFFFF))
	(((ip & mask) == (net & mask))) || return 1
	local host=$((ip & ~mask & 0xFFFFFFFF)) top=$((~mask & 0xFFFFFFFF))
	((host > 1 && host < top))
}

_config_errors=()
_need() { # _need KEY VALIDATOR MESSAGE
	local value=${!1-}
	"$2" "$value" || _config_errors+=("$1=${value:-<empty>}: $3")
}
_need_each() { # _need_each KEY VALIDATOR MESSAGE (space-separated list)
	local item items
	read -ra items <<<"${!1-}"
	for item in "${items[@]}"; do
		"$2" "$item" || _config_errors+=("$1: '$item' $3")
	done
}

config_validate() {
	_config_errors=()

	_need BURROW_MODE is_mode "must be 'stealth' or 'simple'"
	# Every value reaches compose.env, so every key is checked in every mode.
	_need HTTP_PORT is_port "must be 1-65535 (port 80 is needed for Let's Encrypt HTTP-01)"
	_need DECOY_IP is_ipv4 "must be an IPv4 address inside EDGE_SUBNET"
	_need TLS_MODE is_tls_mode "must be 'acme' or 'internal'"
	[[ -z $ACME_EMAIL ]] || _need ACME_EMAIL is_email "is not an email address"
	[[ -z $ACME_CA ]] || _need ACME_CA is_https_url "must be an https:// ACME directory URL"
	if [[ $BURROW_MODE == stealth ]]; then
		_need DOMAIN is_hostname "stealth mode needs a domain you own, pointed at this server (lowercase FQDN)"
	elif [[ $BURROW_MODE == simple ]]; then
		_need COVER_DOMAIN is_hostname "simple mode needs a real HTTPS site to impersonate (lowercase FQDN)"
		[[ -n $LINK_HOST ]] || _need PUBLIC_IPV4 is_ipv4 "simple mode needs the server's public IPv4 (or set LINK_HOST)"
	fi

	if ! secret_is_valid "$SECRET"; then
		_config_errors+=("SECRET: missing or not a FakeTLS (ee...) secret. Run: ./burrow rotate")
	elif [[ $(secret_host "$SECRET") != "$(config_front_host)" ]]; then
		_config_errors+=("SECRET: encodes '$(secret_host "$SECRET")' but the fronting host is '$(config_front_host)'. Run: ./burrow rotate")
	fi

	[[ -z $PUBLIC_IPV4 ]] || _need PUBLIC_IPV4 is_ipv4 "is not an IPv4 address"
	[[ -z $PUBLIC_IPV6 ]] || _need PUBLIC_IPV6 is_ipv6 "is not an IPv6 address"
	[[ -z $LINK_HOST ]] || { is_hostname "$LINK_HOST" || is_ip "$LINK_HOST"; } ||
		_config_errors+=("LINK_HOST=$LINK_HOST: must be a hostname or IP")

	_need BIND_ADDR is_bind_addr "must be an IPv4 address such as 0.0.0.0 or 127.0.0.1"
	_need PROXY_PORT is_port "must be 1-65535"
	_need METRICS_PORT is_port "must be 1-65535 (it is only ever bound to 127.0.0.1)"
	if [[ $BURROW_MODE == stealth && $PROXY_PORT == "$HTTP_PORT" ]]; then
		_config_errors+=("HTTP_PORT: must differ from PROXY_PORT")
	fi
	_need ENABLE_IPV6 is_bool "must be true or false"
	_need EDGE_SUBNET is_cidr4 "must be an IPv4 CIDR such as 10.203.47.0/28"
	if is_ipv4 "$DECOY_IP" && is_cidr4 "$EDGE_SUBNET"; then
		ip_in_subnet "$DECOY_IP" "$EDGE_SUBNET" ||
			_config_errors+=("DECOY_IP=$DECOY_IP: must be a host address inside EDGE_SUBNET=$EDGE_SUBNET (not .0, .1 or broadcast)")
	fi
	_need EDGE_SUBNET6 is_cidr6 "must be an IPv6 CIDR such as fd42:7572:726f:77::/64"

	_need DNS_RESOLVER is_dns_uri "must be https://IP, tls://host, udp://IP or an IP"
	_need PREFER_IP is_prefer_ip "must be prefer-ipv4, prefer-ipv6, only-ipv4 or only-ipv6"
	_need_each UPSTREAM_PROXIES is_socks5_url "is not socks5://[user:pass@]host:port"

	_need TIME_SKEW is_duration "must be a duration such as 5s"
	_need ANTI_REPLAY_SIZE is_bytes "must be a size such as 1mib"
	_need BLOCKLIST_ENABLED is_bool "must be true or false"
	_need_each BLOCKLIST_URLS is_http_url "is not an http(s) URL"
	_need_each ALLOWLIST_URLS is_http_url "is not an http(s) URL"
	_need_each DOPPELGANGER_URLS is_https_url "is not an https URL"
	local list
	for list in LOCAL_BLOCKLIST LOCAL_ALLOWLIST; do
		[[ -z ${!list} ]] && continue
		if ! is_abs_path "${!list}"; then
			_config_errors+=("$list=${!list}: must be an absolute path")
		elif [[ ! -r ${!list} ]]; then
			_config_errors+=("$list=${!list}: file is not readable")
		fi
	done

	_need CONCURRENCY is_count "must be a positive integer without leading zeros"
	_need IDLE_TIMEOUT is_duration "must be a duration such as 5m"
	_need MTG_MEMORY_LIMIT is_mem "must look like 512m or 1g"
	_need DECOY_MEMORY_LIMIT is_mem "must look like 256m or 1g"
	[[ $LOGGING == on || $LOGGING == off ]] || _config_errors+=("LOGGING=$LOGGING: must be on or off")
	_need DEBUG is_bool "must be true or false"

	if ((${#_config_errors[@]})); then
		local e
		for e in "${_config_errors[@]}"; do fail "$e"; done
		return 1
	fi
}

# socks5://user:pass@host:port -> socks5://***@host:port, for display.
redact_userinfo() {
	local items item out=()
	read -ra items <<<"$1"
	for item in "${items[@]}"; do
		if [[ $item == *://*@* ]]; then item="${item%%://*}://***@${item##*@}"; fi
		out+=("$item")
	done
	printf '%s\n' "${out[*]}"
}

# Replace (or append) one KEY=value line, preserving everything else.
config_set_value() {
	local file=$1 key=$2 value=$3 line found=0
	config_is_known_key "$key" || die "unknown setting $key"
	{
		while IFS= read -r line || [[ -n $line ]]; do
			if [[ $line =~ ^${key}= ]]; then
				printf '%s=%s\n' "$key" "$value"
				found=1
			else
				printf '%s\n' "$line"
			fi
		done <"$file"
		((found)) || printf '%s=%s\n' "$key" "$value"
	} | write_atomic "$file" 600
}

# Write a fresh, documented .env from the current values.
config_write() {
	local file=$1
	write_atomic "$file" 600 <<EOF
# burrow configuration. Generated by \`./burrow init\` on $(date -u +%Y-%m-%d).
# This file holds your proxy SECRET: keep it private (mode 0600) and back it up.
# After editing, apply with: ./burrow up        Reference: README.md#configuration

# --- Identity --------------------------------------------------------------
# stealth: your own domain, a real decoy website and a real TLS certificate (recommended)
# simple:  no domain needed; impersonate COVER_DOMAIN (works, but easier to spot)
BURROW_MODE=$BURROW_MODE
DOMAIN=$DOMAIN
COVER_DOMAIN=$COVER_DOMAIN
# Rotate with \`./burrow rotate\`. Rotating revokes every link shared so far.
SECRET=$SECRET
PUBLIC_IPV4=$PUBLIC_IPV4
PUBLIC_IPV6=$PUBLIC_IPV6
# What share links point at. Default: DOMAIN (stealth) or PUBLIC_IPV4 (simple).
LINK_HOST=$LINK_HOST

# --- Network ---------------------------------------------------------------
BIND_ADDR=$BIND_ADDR
PROXY_PORT=$PROXY_PORT
HTTP_PORT=$HTTP_PORT
METRICS_PORT=$METRICS_PORT
ENABLE_IPV6=$ENABLE_IPV6
EDGE_SUBNET=$EDGE_SUBNET
DECOY_IP=$DECOY_IP
EDGE_SUBNET6=$EDGE_SUBNET6

# --- TLS for the decoy site (stealth mode) ---------------------------------
TLS_MODE=$TLS_MODE
ACME_EMAIL=$ACME_EMAIL
ACME_CA=$ACME_CA

# --- Upstream --------------------------------------------------------------
DNS_RESOLVER=$DNS_RESOLVER
PREFER_IP=$PREFER_IP
# Optional socks5:// upstreams, space-separated, if Telegram is blocked from this server.
UPSTREAM_PROXIES=$UPSTREAM_PROXIES

# --- Defenses --------------------------------------------------------------
TIME_SKEW=$TIME_SKEW
ANTI_REPLAY_SIZE=$ANTI_REPLAY_SIZE
BLOCKLIST_ENABLED=$BLOCKLIST_ENABLED
BLOCKLIST_URLS="$BLOCKLIST_URLS"
LOCAL_BLOCKLIST=$LOCAL_BLOCKLIST
ALLOWLIST_URLS="$ALLOWLIST_URLS"
LOCAL_ALLOWLIST=$LOCAL_ALLOWLIST
DOPPELGANGER_URLS="$DOPPELGANGER_URLS"

# --- Capacity --------------------------------------------------------------
CONCURRENCY=$CONCURRENCY
IDLE_TIMEOUT=$IDLE_TIMEOUT
MTG_MEMORY_LIMIT=$MTG_MEMORY_LIMIT
DECOY_MEMORY_LIMIT=$DECOY_MEMORY_LIMIT

# --- Observability ---------------------------------------------------------
# off = no container logs at all (mtg logs client IPs at info level).
LOGGING=$LOGGING
DEBUG=$DEBUG
EOF
}
