#!/usr/bin/env bats
# The effective Docker Compose model, for every mode and overlay.

setup() {
	load ../helpers
	require_docker
	command -v jq >/dev/null 2>&1 || skip "jq is not installed"
	isolate
	burrow init --domain notes.example.org --ipv4 203.0.113.7 --quiet
}

# model [config set args...]: render and print the compose model as JSON.
model() {
	(($#)) && burrow config set "$@" >/dev/null
	burrow render >/dev/null
	(
		# shellcheck source=/dev/null
		for lib in common validate secret links config render compose; do source "$BURROW_ROOT/lib/$lib.sh"; done
		ENV_FILE=$BURROW_ENV_FILE STATE_DIR=$BURROW_STATE_DIR
		config_load "$ENV_FILE"
		compose config --format json
	)
}

@test "every container is locked down" {
	json=$(model)
	for svc in mtg decoy; do
		jq -e --arg s "$svc" '.services[$s] |
			.read_only == true and .cap_drop == ["ALL"] and
			(.security_opt | index("no-new-privileges:true")) != null and
			.user == "65534:65534" and .mem_limit != null and .pids_limit > 0 and
			.restart == "unless-stopped"' <<<"$json"
	done
	jq -e '.services["decoy-init"] | .cap_add == ["CHOWN"] and .cap_drop == ["ALL"] and .network_mode == "none"' <<<"$json"
}

@test "only the proxy, HTTP and loopback metrics are published" {
	json=$(model)
	run jq -c '[.services[] | select(.ports) | .ports[] | {target, published, host_ip}] | sort_by(.target)' <<<"$json"
	assert_output '[{"target":3128,"published":"443","host_ip":"0.0.0.0"},{"target":3129,"published":"3129","host_ip":"127.0.0.1"},{"target":8080,"published":"80","host_ip":"0.0.0.0"}]'
}

@test "the decoy gets the fixed address mtg fronts to" {
	json=$(model)
	jq -e '.services.decoy.networks.edge.ipv4_address == "10.203.47.10"' <<<"$json"
	grep -q 'host = "10.203.47.10"' "$BURROW_STATE_DIR/mtg.toml"
}

@test "simple mode runs mtg alone" {
	burrow init --cover-domain www.example.com --ipv4 203.0.113.7 --quiet --force
	run jq -r '.services | keys | join(",")' <<<"$(model)"
	assert_output mtg
}

@test "IPv6 overlay: dual-stack network and an IPv6 listener" {
	json=$(model ENABLE_IPV6 true)
	jq -e '.networks.edge.enable_ipv6 == true and (.networks.edge.ipam.config | length) == 2' <<<"$json"
	jq -e '[.services.mtg.ports[] | select(.host_ip == "::")] | length == 1' <<<"$json"
	grep -q 'bind-to = "\[::\]:3128"' "$BURROW_STATE_DIR/mtg.toml"
}

@test "LOGGING=off drops all container logs" {
	run jq -r '.services.mtg.logging.driver + "," + .services.decoy.logging.driver' <<<"$(model LOGGING off)"
	assert_output none,none
}

@test "config changes move the right container label" {
	a=$(model)
	b=$(model CONCURRENCY 1024)
	[[ $(jq -r '.services.mtg.labels["io.burrow.config-hash"]' <<<"$a") != "$(jq -r '.services.mtg.labels["io.burrow.config-hash"]' <<<"$b")" ]]
	[[ $(jq -r '.services.decoy.labels["io.burrow.config-hash"]' <<<"$a") == "$(jq -r '.services.decoy.labels["io.burrow.config-hash"]' <<<"$b")" ]]
}

@test "third-party images are pinned by digest" {
	run grep -E '^\s+image:' "$BURROW_ROOT/compose.yaml"
	for line in "${lines[@]}"; do
		[[ $line == *burrow-tools* || $line == *@sha256:* ]] || {
			echo "not pinned: $line"
			return 1
		}
	done
	grep -q '^ARG PYTHON_IMAGE=python:.*@sha256:' "$BURROW_ROOT/tools/Dockerfile"
}
