# shellcheck shell=bash
# FakeTLS secrets: "ee" + 16 random bytes + hex(fronting hostname).

hex_encode() {
	printf '%s' "$1" | od -An -tx1 -v | tr -d ' \n'
}

hex_decode() {
	local hex=$1
	[[ $hex =~ ^([0-9a-f]{2})*$ ]] || return 1
	# Turn "6162" into "\x61\x62" and let printf decode it. (sed, not
	# ${var//}: replacement back-references need bash 5.2.)
	# shellcheck disable=SC2001
	printf '%b' "$(sed 's/../\\x&/g' <<<"$hex")"
}

secret_new() {
	local host=$1
	is_hostname "$host" || return 1
	printf 'ee%s%s\n' "$(random_hex 16)" "$(hex_encode "$host")"
}

secret_is_valid() {
	[[ $1 =~ ^ee[0-9a-f]{32}([0-9a-f]{2})+$ ]] || return 1
	local host
	host=$(secret_host "$1") && is_hostname "$host"
}

# Print the fronting hostname embedded in a secret.
secret_host() {
	[[ $1 =~ ^ee[0-9a-f]{32}([0-9a-f]{2})+$ ]] || return 1
	hex_decode "${1:34}"
}

# Never print a full secret in logs.
secret_redact() {
	printf '%s…%s\n' "${1:0:6}" "${1: -4}"
}
