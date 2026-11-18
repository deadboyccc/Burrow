#!/usr/bin/env bats

setup() {
	load ../helpers
	load_libs
}

@test "hostnames: accepts lowercase FQDNs" {
	for h in example.org notes.alice.dev a-b.c-d.io xn--80ak6aa92e.com "$(printf 'a%.0s' {1..63}).org"; do
		run is_hostname "$h"
		assert_success
	done
}

@test "hostnames: rejects everything else" {
	for h in "" localhost Example.org -a.org a-.org a..org .a.org a.org. "a b.org" 'a$.org' 1.2.3.4 \
		"$(printf 'a%.0s' {1..64}).org" "a.org;rm" 'a.org"' "a.org'"; do
		run is_hostname "$h"
		assert_failure
	done
}

@test "ipv4: valid and invalid" {
	for ip in 0.0.0.0 127.0.0.1 203.0.113.7 255.255.255.255; do
		run is_ipv4 "$ip"
		assert_success
	done
	for ip in "" 256.1.1.1 1.2.3 1.2.3.4.5 01.2.3.4 a.b.c.d " 1.2.3.4"; do
		run is_ipv4 "$ip"
		assert_failure
	done
}

@test "ipv6: valid and invalid" {
	for ip in ::1 2001:db8::1 fd42:7572:726f:77::10 2001:0db8:0000:0000:0000:0000:0000:0001; do
		run is_ipv6 "$ip"
		assert_success
	done
	for ip in "" 1.2.3.4 2001:db8:::1 1::2::3 'fe80::1%eth0' g::1; do
		run is_ipv6 "$ip"
		assert_failure
	done
}

@test "ports" {
	for p in 1 80 443 65535; do
		run is_port "$p"
		assert_success
	done
	for p in 0 65536 -1 "" 44a 080000; do
		run is_port "$p"
		assert_failure
	done
}

@test "cidrs" {
	run is_cidr4 10.203.47.0/28
	assert_success
	run is_cidr4 10.0.0.0/33
	assert_failure
	run is_cidr4 10.0.0.0
	assert_failure
	run is_cidr6 fd42:7572:726f:77::/64
	assert_success
	run is_cidr6 fd42::/129
	assert_failure
}

@test "durations, sizes and memory limits" {
	for v in 5s 500ms 1m30s 24h; do
		run is_duration "$v"
		assert_success
	done
	for v in 5 5d s 1.5s; do
		run is_duration "$v"
		assert_failure
	done
	run is_bytes 1mib
	assert_success
	run is_bytes 128KiB
	assert_success
	run is_bytes 1mb
	assert_failure
	run is_mem 512m
	assert_success
	run is_mem 512mb
	assert_failure
}

@test "urls: https, socks5 and DNS" {
	run is_https_url https://iplists.firehol.org/files/firehol_abusers_1d.netset
	assert_success
	run is_https_url 'https://a.org/x"y'
	assert_failure
	run is_http_url http://example.org/list.netset
	assert_success
	run is_socks5_url socks5://user:pa55@10.0.0.2:1080
	assert_success
	run is_socks5_url socks5://10.0.0.2
	assert_failure
	run is_socks5_url 'socks5://u:p"@h:1'
	assert_failure
	for d in https://1.1.1.1 https://cloudflare-dns.com/dns-query tls://dns.quad9.net 9.9.9.9 udp://9.9.9.9:53; do
		run is_dns_uri "$d"
		assert_success
	done
	run is_dns_uri ftp://x
	assert_failure
}

@test "enumerations" {
	run is_mode stealth
	assert_success
	run is_mode fast
	assert_failure
	run is_tls_mode internal
	assert_success
	run is_prefer_ip only-ipv6
	assert_success
	run is_prefer_ip ipv6
	assert_failure
	run is_bool true
	assert_success
	run is_bool yes
	assert_failure
}

@test "absolute paths" {
	run is_abs_path /etc/burrow/block.netset
	assert_success
	for p in relative/path /a/../etc/shadow '/a b' '/a;b'; do
		run is_abs_path "$p"
		assert_failure
	done
}

@test "ipv6: strict group structure" {
	for ip in :: ::1 1:: 2001:db8:0:0:0:0:0:1 fe80::a:b:c:d; do
		run is_ipv6 "$ip"
		assert_success
	done
	for ip in : 1:2:3 1:2:3:4:5:6:7:8:9 :1:2:3:4:5:6:7 12345::1 1::2:3:4:5:6:7:8 ::ffff:1.2.3.4; do
		run is_ipv6 "$ip"
		assert_failure
	done
}

@test "counts are positive and TOML-safe" {
	run is_count 8192
	assert_success
	for v in 0 0123 -1 "" 1e3 99999999999; do
		run is_count "$v"
		assert_failure
	done
}
