# shellcheck shell=bash
# shellcheck disable=SC2153 # settings are globals loaded by config.sh
# Render validated config into the files the containers read (STATE_DIR):
#   mtg.toml     proxy configuration
#   Caddyfile    decoy web server (stealth mode)
#   site/        decoy website, personalised for DOMAIN
#   lists/       local IP block/allow lists
#   compose.env  the only variables docker compose interpolates
# Values were validated by config_validate, so they are safe to interpolate.

toml_array() {
	local items quoted=() item
	read -ra items <<<"$1"
	for item in "${items[@]}"; do quoted+=("\"$item\""); done
	printf '[%s]' "$(join_by ', ' "${quoted[@]}")"
}

render_mtg_toml() {
	local bind="0.0.0.0:3128" block_urls='' allow_urls=$ALLOWLIST_URLS
	[[ $ENABLE_IPV6 == true ]] && bind="[::]:3128"
	[[ $BLOCKLIST_ENABLED == true ]] && block_urls=$BLOCKLIST_URLS
	[[ -n $LOCAL_BLOCKLIST ]] && block_urls+=" /lists/blocklist.netset"
	[[ -n $LOCAL_ALLOWLIST ]] && allow_urls+=" /lists/allowlist.netset"
	local block_on=false allow_on=false
	[[ -n ${block_urls// /} ]] && block_on=true
	[[ -n ${allow_urls// /} ]] && allow_on=true

	cat <<EOF
# Rendered by burrow from .env. Do not edit: change .env, then ./burrow up
debug = $DEBUG
secret = "$SECRET"
bind-to = "$bind"
concurrency = $CONCURRENCY
prefer-ip = "$PREFER_IP"
auto-update = false
tolerate-time-skewness = "$TIME_SKEW"
allow-fallback-on-unknown-dc = false
EOF
	[[ -n $PUBLIC_IPV4 ]] && printf 'public-ipv4 = "%s"\n' "$PUBLIC_IPV4"
	[[ -n $PUBLIC_IPV6 ]] && printf 'public-ipv6 = "%s"\n' "$PUBLIC_IPV6"

	printf '\n# Anything that is not a valid FakeTLS hello for our secret is spliced here.\n[domain-fronting]\n'
	if [[ $BURROW_MODE == stealth ]]; then
		# A literal IP: mtg resolves names through its own DoH resolver, which
		# knows nothing about Docker's internal DNS.
		printf 'host = "%s"\nport = 8443\n' "$DECOY_IP"
	else
		printf 'port = 443\n'
	fi

	cat <<EOF

[network]
dns = "$DNS_RESOLVER"
proxies = $(toml_array "$UPSTREAM_PROXIES")

[network.timeout]
tcp = "5s"
http = "10s"
idle = "$IDLE_TIMEOUT"
handshake = "10s"

[network.keep-alive]
disabled = false
idle = "15s"
interval = "15s"
count = 9

[defense.anti-replay]
enabled = true
max-size = "$ANTI_REPLAY_SIZE"
error-rate = 0.001

[defense.blocklist]
enabled = $block_on
download-concurrency = 2
urls = $(toml_array "$block_urls")
update-each = "24h"

[defense.allowlist]
enabled = $allow_on
download-concurrency = 2
urls = $(toml_array "$allow_urls")
update-each = "24h"

[defense.doppelganger]
urls = $(toml_array "$DOPPELGANGER_URLS")
repeats-per-raid = 10
raid-each = "6h"
drs = false

[stats.prometheus]
enabled = true
bind-to = "0.0.0.0:3129"
http-path = "/metrics"
metric-prefix = "mtg"
EOF
}

render_caddyfile() {
	local globals=''
	[[ -n $ACME_EMAIL ]] && globals+=$'\temail '"$ACME_EMAIL"$'\n'
	[[ -n $ACME_CA ]] && globals+=$'\tacme_ca '"$ACME_CA"$'\n'
	[[ $TLS_MODE == internal ]] && globals+=$'\tskip_install_trust\n'
	local tls_line=''
	[[ $TLS_MODE == internal ]] && tls_line=$'\ttls internal\n'

	cat <<EOF
# Rendered by burrow from .env. Do not edit: change .env, then ./burrow up
#
# This is the website the world sees at https://$DOMAIN. mtg owns the public
# TLS port and splices every connection that is not a valid FakeTLS hello for
# our secret to this server, so browsers, scanners and censors' probes all
# get a genuine site with a genuine certificate.
{
	admin off
	persist_config off
	http_port 8080
	https_port 8443
	# Redirects are explicit below: automatic ones would leak port 8443.
	auto_https disable_redirects
${globals}	servers {
		# No HTTP/3: the UDP port is not published, and advertising h3
		# without a listener would be an odd fingerprint.
		protocols h1 h2
	}
}

$DOMAIN {
${tls_line}	root * /srv
	encode zstd gzip
	header {
		Strict-Transport-Security "max-age=31536000"
		X-Content-Type-Options "nosniff"
		Referrer-Policy "strict-origin-when-cross-origin"
		Content-Security-Policy "default-src 'none'; style-src 'self'; img-src 'self'; base-uri 'none'; form-action 'none'; frame-ancestors 'none'"
	}
	file_server
	handle_errors 404 {
		rewrite * /404.html
		file_server {
			status 404
		}
	}
}

http://$DOMAIN {
	redir https://{host}{uri} permanent
}

# Container-local health endpoint for the Docker healthcheck. Not published.
http://127.0.0.1:2020 {
	bind 127.0.0.1
	respond /healthz "ok" 200
}
EOF
}

# A human-ish site name from the domain: notes.alice.dev -> Alice
site_name() {
	local domain=$1 labels name
	IFS=. read -ra labels <<<"$domain"
	if ((${#labels[@]} >= 2)); then name=${labels[-2]}; else name=${labels[0]}; fi
	name=${name//-/ }
	printf '%s\n' "${name^}"
}

site_accent() {
	local palette=("#2f6f4f" "#7a4b2a" "#3b5b8c" "#8c3b5b" "#5b3b8c" "#2a6d7a" "#7a6a2a" "#6b4f2f")
	local h
	h=$(printf '%s' "$1" | sha256_stdin)
	printf '%s\n' "${palette[$((16#${h:0:2} % ${#palette[@]}))]}"
}

site_source_dir() {
	if [[ -d $BURROW_ROOT/site.local ]]; then
		printf '%s\n' "$BURROW_ROOT/site.local"
	else
		printf '%s\n' "$BURROW_ROOT/site"
	fi
}

render_site() {
	local dest=$1 src name accent year file content
	src=$(site_source_dir)
	name=$(site_name "$DOMAIN")
	accent=$(site_accent "$DOMAIN")
	year=$(date -u +%Y)

	rm -rf "$dest.new"
	mkdir -p "$dest.new"
	cp -R "$src/." "$dest.new/"
	while IFS= read -r -d '' file; do
		content=$(<"$file")
		content=${content//"{{SITE_NAME}}"/"$name"}
		content=${content//"{{DOMAIN}}"/"$DOMAIN"}
		content=${content//"{{YEAR}}"/"$year"}
		content=${content//"{{ACCENT}}"/"$accent"}
		printf '%s\n' "$content" >"$file"
	done < <(find "$dest.new" -type f \( -name '*.html' -o -name '*.css' -o -name '*.txt' -o -name '*.xml' -o -name '*.svg' -o -name '*.webmanifest' \) -print0)
	find "$dest.new" -type d -exec chmod 0755 {} +
	find "$dest.new" -type f -exec chmod 0644 {} +
	# Swap only on change: the decoy bind-mounts this directory, and its
	# config-hash label (which changes with the content) is what makes
	# compose recreate it onto the new directory.
	if [[ -d $dest && $(cd "$dest" && hash_paths .) == $(cd "$dest.new" && hash_paths .) ]]; then
		rm -rf -- "$dest.new"
	else
		rm -rf -- "$dest"
		mv "$dest.new" "$dest"
	fi
}

render_lists() {
	local dir=$1
	mkdir -p "$dir"
	chmod 0755 "$dir"
	if [[ -n $LOCAL_BLOCKLIST ]]; then write_if_changed "$dir/blocklist.netset" 644 <"$LOCAL_BLOCKLIST"; else rm -f -- "$dir/blocklist.netset"; fi
	if [[ -n $LOCAL_ALLOWLIST ]]; then write_if_changed "$dir/allowlist.netset" 644 <"$LOCAL_ALLOWLIST"; else rm -f -- "$dir/allowlist.netset"; fi
}

render_compose_env() {
	cat <<EOF
# Rendered by burrow. Variables for docker compose interpolation only.
BURROW_VERSION=$BURROW_VERSION
BURROW_STATE_DIR=$STATE_DIR
BIND_ADDR=$BIND_ADDR
PROXY_PORT=$PROXY_PORT
HTTP_PORT=$HTTP_PORT
METRICS_PORT=$METRICS_PORT
EDGE_SUBNET=$EDGE_SUBNET
EDGE_SUBNET6=$EDGE_SUBNET6
DECOY_IP=$DECOY_IP
MTG_MEMORY_LIMIT=$MTG_MEMORY_LIMIT
DECOY_MEMORY_LIMIT=$DECOY_MEMORY_LIMIT
MTG_CONFIG_HASH=$1
DECOY_CONFIG_HASH=$2
EOF
}

# Hash of every file under the given paths, so a config change changes a
# container label and `docker compose up` recreates exactly what changed.
hash_paths() {
	local sum=(sha256sum)
	command -v sha256sum >/dev/null 2>&1 || sum=(shasum -a 256)
	find "$@" -type f -print0 2>/dev/null | LC_ALL=C sort -z | xargs -0 -r "${sum[@]}" | sha256_stdin
}

render_all() {
	umask 077
	mkdir -p "$STATE_DIR" "$STATE_DIR/share"
	chmod 0700 "$STATE_DIR" "$STATE_DIR/share"

	# 0644 inside a 0700 directory: the container user (65534) can read the
	# bind-mounted file, other host users cannot reach it.
	render_mtg_toml | write_if_changed "$STATE_DIR/mtg.toml" 644
	render_lists "$STATE_DIR/lists"
	if [[ $BURROW_MODE == stealth ]]; then
		render_caddyfile | write_if_changed "$STATE_DIR/Caddyfile" 644
		render_site "$STATE_DIR/site"
	else
		# Compose validates bind sources of inactive services too.
		printf '# unused in simple mode\n' | write_if_changed "$STATE_DIR/Caddyfile" 644
		mkdir -p "$STATE_DIR/site"
		chmod 0755 "$STATE_DIR/site"
	fi

	local mtg_hash decoy_hash
	mtg_hash=$(hash_paths "$STATE_DIR/mtg.toml" "$STATE_DIR/lists")
	decoy_hash=$(hash_paths "$STATE_DIR/Caddyfile" "$STATE_DIR/site")
	render_compose_env "${mtg_hash:0:16}" "${decoy_hash:0:16}" | write_if_changed "$STATE_DIR/compose.env" 600
}
