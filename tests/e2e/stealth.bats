#!/usr/bin/env bats
# A real stealth-mode stack on 127.0.0.1: the same images and config as
# production, except a self-signed certificate (TLS_MODE=internal) because
# Let's Encrypt cannot reach a test machine.
#
# Needs Docker. Telegram round trips need the internet; set
# BURROW_E2E_OFFLINE=1 to skip only those.

DOMAIN=e2e.burrow.test

setup_file() {
	load ../helpers
	have_docker || return 0
	export BURROW_ENV_FILE=$BATS_FILE_TMPDIR/.env BURROW_STATE_DIR=$BATS_FILE_TMPDIR/state
	export BURROW_PROJECT=burrow-e2e-$$
	PROXY_PORT=$(free_port_host) HTTP_PORT=$(free_port_host) METRICS_PORT=$(free_port_host)
	export PROXY_PORT HTTP_PORT METRICS_PORT
	burrow init --domain "$DOMAIN" --tls internal --bind 127.0.0.1 --port "$PROXY_PORT" \
		--http-port "$HTTP_PORT" --metrics-port "$METRICS_PORT" --ipv4 127.0.0.1 --link-host 127.0.0.1 \
		--no-blocklist --subnet "$(random_subnet)" --quiet
	burrow up >&3 2>&1
}

teardown_file() {
	load ../helpers
	have_docker || return 0
	burrow down --volumes >/dev/null 2>&1 || true
}

setup() {
	load ../helpers
	require_docker
}

free_port_host() {
	(
		# shellcheck source=/dev/null
		source "$BURROW_ROOT/lib/common.sh"
		free_port
	)
}

container() { docker compose -p "$BURROW_PROJECT" ps -q "$1"; }
telegram_flag() { [[ ${BURROW_E2E_OFFLINE:-0} == 1 ]] && echo --no-telegram || true; }

tools_host() { # tools_host SECRET ARGS...
	local secret=$1
	shift
	BURROW_SECRET=$secret docker run --rm --network host -e BURROW_SECRET \
		"burrow-tools:$(burrow version | cut -d' ' -f2)" "$@"
}

@test "smoke: every check passes from inside the stack" {
	# shellcheck disable=SC2046
	run burrow smoke $(telegram_flag)
	assert_success
	assert_output --partial "checks passed"
}

@test "smoke --link: the share link works from the host, as an app would use it" {
	# shellcheck disable=SC2046
	run burrow smoke --link "$(burrow link --format tg)" --insecure $(telegram_flag)
	assert_success
}

@test "smoke --link: links with the base64 form of the secret work too" {
	b64=$(python3 -c 'import base64, sys; print(base64.urlsafe_b64encode(bytes.fromhex(sys.argv[1])).decode().rstrip("="))' \
		"$(burrow config get SECRET)")
	run burrow smoke --link "tg://proxy?server=127.0.0.1&port=$PROXY_PORT&secret=$b64" --insecure --no-telegram
	assert_success
}

@test "status reports a healthy proxy and traffic counters" {
	run burrow status
	assert_success
	assert_output --partial "FakeTLS handshake succeeds"
	assert_output --partial "probes sent to decoy"
}

@test "running containers are hardened" {
	for svc in mtg decoy; do
		run docker inspect -f '{{.HostConfig.ReadonlyRootfs}} {{.HostConfig.CapDrop}} {{.HostConfig.SecurityOpt}} {{.Config.User}} {{.HostConfig.RestartPolicy.Name}}' "$(container "$svc")"
		assert_output "true [ALL] [no-new-privileges:true] 65534:65534 unless-stopped"
		read -r memory pids < <(docker inspect -f '{{.HostConfig.Memory}} {{json .HostConfig.PidsLimit}}' "$(container "$svc")")
		((memory > 0 && pids > 0))
	done
}

@test "only the intended ports are published, metrics on loopback only" {
	run docker port "$(container mtg)"
	assert_output --partial "3128/tcp -> 127.0.0.1:$PROXY_PORT"
	assert_output --partial "3129/tcp -> 127.0.0.1:$METRICS_PORT"
	assert_equal "${#lines[@]}" 2
	run docker port "$(container decoy)"
	assert_output "8080/tcp -> 127.0.0.1:$HTTP_PORT"
}

@test "the decoy website: personalised pages, 404s, security headers" {
	base=(curl -sk --max-time 10 --resolve "$DOMAIN:$PROXY_PORT:127.0.0.1")
	run "${base[@]}" "https://$DOMAIN:$PROXY_PORT/"
	assert_success
	assert_output --partial "<title>Burrow · notes</title>"
	refute_output --partial "{{"
	run "${base[@]}" -o /dev/null -w '%{http_code}' "https://$DOMAIN:$PROXY_PORT/notes/film.html"
	assert_output 200
	run "${base[@]}" -w '\n%{http_code}' "https://$DOMAIN:$PROXY_PORT/wp-login.php"
	[[ ${lines[-1]} == 404 ]]
	assert_output --partial "Not found"
	headers=$("${base[@]}" -I "https://$DOMAIN:$PROXY_PORT/")
	grep -qi '^strict-transport-security: max-age=31536000' <<<"$headers"
	grep -qi '^x-content-type-options: nosniff' <<<"$headers"
	grep -qi '^server: Caddy' <<<"$headers"
}

@test "plain HTTP redirects to the public HTTPS port, never the internal one" {
	run curl -s --max-time 10 -o /dev/null -w '%{http_code} %{redirect_url}' -H "Host: $DOMAIN" "http://127.0.0.1:$HTTP_PORT/about.html"
	# The test stack's proxy port is not 443, so the redirect must carry it.
	assert_output "301 https://$DOMAIN:$PROXY_PORT/about.html"
	refute_output --partial ":8443"
}

@test "metrics count probes that were sent to the decoy" {
	run curl -fsS --max-time 5 "http://127.0.0.1:$METRICS_PORT/metrics"
	assert_success
	fronted=$(awk '/^mtg_domain_fronting / {print $2}' <<<"$output")
	((${fronted%.*} > 0))
}

@test "share writes private QR files" {
	run burrow share
	assert_success
	[[ $(head -c 8 "$BURROW_STATE_DIR/share/burrow-proxy.png" | od -An -tx1 | tr -d ' \n') == 89504e470d0a1a0a ]]
	[[ $(stat -c %a "$BURROW_STATE_DIR/share/burrow-proxy.png") == 600 ]]
	grep -q '<svg' "$BURROW_STATE_DIR/share/burrow-proxy.svg"
}

@test "logs are available and never contain the secret" {
	run burrow logs mtg
	assert_success
	refute_output --partial "$(burrow config get SECRET)"
}

@test "a config change recreates only the container it affects" {
	mtg_before=$(container mtg) decoy_before=$(container decoy)
	burrow config set CONCURRENCY 4096
	run burrow up
	assert_success
	[[ $(container mtg) != "$mtg_before" ]]
	[[ $(container decoy) == "$decoy_before" ]]
	grep -q '^concurrency = 4096$' "$BURROW_STATE_DIR/mtg.toml"
}

@test "rotate: the old link stops working, the new one works" {
	old=$(burrow config get SECRET)
	run burrow rotate --yes
	assert_success
	new=$(burrow config get SECRET)
	run tools_host "$old" probe --host 127.0.0.1 --port "$PROXY_PORT" --expect fronted
	assert_success
	run tools_host "$new" probe --host 127.0.0.1 --port "$PROXY_PORT" --retries 5
	assert_success
}

@test "a crashed proxy is restarted by Docker" {
	pid=$(docker inspect -f '{{.State.Pid}}' "$(container mtg)")
	if ((EUID == 0)); then kill -9 "$pid"; elif sudo -n true 2>/dev/null; then sudo kill -9 "$pid"; else skip "needs root to kill the container process"; fi
	for _ in {1..30}; do
		[[ $(docker inspect -f '{{.RestartCount}}' "$(container mtg)") -ge 1 ]] && break
		sleep 1
	done
	run tools_host "$(burrow config get SECRET)" probe --host 127.0.0.1 --port "$PROXY_PORT" --retries 20
	assert_success
}

@test "the watchdog recreates a hung proxy" {
	before=$(container mtg)
	docker pause "$before" >/dev/null
	BURROW_WATCHDOG_TIMEOUT=3 run burrow watchdog
	assert_success
	[[ $(container mtg) != "$before" ]]
	run burrow watchdog
	assert_output --partial "proxy healthy"
}

@test "doctor passes (findings that are expected with self-signed TLS are warnings)" {
	run burrow doctor
	assert_success
	assert_output --partial "is valid (stealth mode)"
}

@test "down keeps the certificate volume; up brings everything back" {
	run burrow down
	assert_success
	docker volume inspect "${BURROW_PROJECT}_decoy-data" >/dev/null
	run burrow up
	assert_success
	run burrow smoke --no-telegram
	assert_success
}
