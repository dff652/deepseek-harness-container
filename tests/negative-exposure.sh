#!/usr/bin/env bash
set -Eeuo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

compose="$ROOT/compose.yaml"
caddyfile="$ROOT/Caddyfile"
[[ -f "$compose" ]] || fail "missing compose.yaml"
[[ -f "$caddyfile" ]] || fail "missing Caddyfile"

# Source-level negative boundaries. These checks intentionally inspect the
# shipped files, not only a developer's current environment.
if command -v rg >/dev/null 2>&1; then
  forbidden_output=$(rg -n -i 'privileged:\s*true|network_mode:\s*host|/var/run/docker\.sock|SYS_ADMIN|NET_ADMIN|(^|[[:space:]])latest([:@[:space:]]|$)' "$compose" || true)
  port_output=$(rg -n '3080:3080|:3080:3080' "$compose" || true)
else
  forbidden_output=$(grep -Eni 'privileged:[[:space:]]*true|network_mode:[[:space:]]*host|/var/run/docker\.sock|SYS_ADMIN|NET_ADMIN|(^|[[:space:]])latest([:@[:space:]]|$)' "$compose" || true)
  port_output=$(grep -En '3080:3080|:3080:3080' "$compose" || true)
fi
if [[ -n "$forbidden_output" ]]; then
  printf '%s\n' "$forbidden_output"
  fail "forbidden Compose exposure or floating version"
fi
if [[ -n "$port_output" ]]; then
  printf '%s\n' "$port_output"
  fail "DSH port 3080 is published"
fi

grep -Fq 'network_mode: service:dsh' "$compose" || fail "Caddy does not share DSH network namespace"
grep -Fq 'condition: service_completed_successfully' "$compose" || fail "Caddy volume initializer is not a required one-shot dependency"
grep -Fq -- '- CHOWN' "$compose" || fail "Caddy initializer lacks its sole required capability"
grep -Fq 'caddy:2.11.4@sha256:1172d4213087d3fc30bafc7ff2c2896180eb0c41ff7f75f315568fb36cabdcba' "$compose" || fail "Caddy image is not pinned to the verified 2.11.4 ARM64 child digest"
grep -Fq 'tls internal' "$caddyfile" || fail "Caddy does not use deployment-local TLS"
# shellcheck disable=SC2016 # Caddy placeholder must remain literal.
grep -Fq 'default_sni {$DSH_LAN_IP}' "$caddyfile" || fail "literal-IP clients without SNI have no default certificate"
grep -Fq 'skip_install_trust' "$caddyfile" || fail "Caddy may try to mutate its read-only trust store"
# shellcheck disable=SC2016 # Caddy placeholder must remain literal.
grep -Fq 'https://{$DSH_LAN_IP} {' "$caddyfile" || fail "approved IP site block missing"
grep -Fq 'https:// {' "$caddyfile" || fail "unapproved Host catch-all site missing"
grep -Fq 'respond "unapproved Host" 421' "$caddyfile" || fail "unapproved Host is not rejected"
grep -Fq '@cross_site header Sec-Fetch-Site cross-site' "$caddyfile" || fail "cross-site Fetch Metadata gate missing"
grep -Fq '@bad_origin expression' "$caddyfile" || fail "Origin equality gate missing"
grep -Fq 'header_up Host 127.0.0.1:3080' "$caddyfile" || fail "loopback Host adapter missing"
grep -Fq 'header_up -Origin' "$caddyfile" || fail "Origin removal is not explicit in loopback adapter"
grep -Fq 'header_up -Sec-Fetch-Site' "$caddyfile" || fail "Fetch Metadata removal is not explicit in loopback adapter"

cross_site_line=$(grep -n -m1 '@cross_site ' "$caddyfile" | cut -d: -f1)
bad_origin_line=$(grep -n -m1 '@bad_origin expression' "$caddyfile" | cut -d: -f1)
basic_auth_line=$(grep -n -m1 '^[[:space:]]*basic_auth[[:space:]]*{' "$caddyfile" | cut -d: -f1)
header_up_line=$(grep -n -m1 'header_up Host' "$caddyfile" | cut -d: -f1)
reverse_proxy_line=$(grep -n -m1 'reverse_proxy 127\.0\.0\.1:3080' "$caddyfile" | cut -d: -f1)
[[ "$cross_site_line" -lt "$header_up_line" ]] || fail "Fetch Metadata gate occurs after upstream adaptation"
[[ "$bad_origin_line" -lt "$header_up_line" ]] || fail "Origin gate occurs after upstream adaptation"
[[ "$basic_auth_line" -lt "$reverse_proxy_line" ]] || fail "Basic Auth occurs after reverse proxy"

# A global header deletion before the trust gate would turn the gate into a
# bypass. Only the nested reverse_proxy adapter may remove these headers.
if awk 'BEGIN{bad=0} /header_up -Origin|header_up -Sec-Fetch-Site/{if ($0 !~ /^[[:space:]]+header_up/) bad=1} END{exit bad}' "$caddyfile"; then
  :
else
  fail "external headers are removed outside the nested upstream adapter"
fi

# Run the full rendered Compose contract as the second, structured check.
"$ROOT/tests/compose-contract.sh"

echo "PASS: negative exposure and request-trust ordering"
