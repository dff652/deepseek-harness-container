#!/usr/bin/env bash
set -Eeuo pipefail

# Create disposable, offline test-only CA and an IP-SAN server PEM.  This
# script never contacts a CA or embeds a production key.  Use a fresh output
# directory and delete it after the test; the runtime test does that for you.

readonly output_dir=${1:?usage: haproxy-test-pki.sh OUTPUT_DIR IP_ADDRESS}
readonly lan_ip=${2:?usage: haproxy-test-pki.sh OUTPUT_DIR IP_ADDRESS}

python3 - "$lan_ip" <<'PY'
import ipaddress
import sys

try:
    ipaddress.ip_address(sys.argv[1])
except ValueError:
    raise SystemExit("IP_ADDRESS must be a literal IPv4 or IPv6 address")
PY

case "$output_dir" in
  ''|/|.|..|*/..|*/.)
    echo "refusing unsafe output directory: $output_dir" >&2
    exit 2
    ;;
esac
if [[ -e "$output_dir" || -L "$output_dir" ]]; then
  echo "output path must not already exist: $output_dir" >&2
  exit 2
fi
umask 077
mkdir -m 700 -- "$output_dir"

readonly ca_key="$output_dir/ca.key"
readonly ca_cert="$output_dir/ca.crt"
readonly server_key="$output_dir/server.key"
readonly server_csr="$output_dir/server.csr"
readonly server_cert="$output_dir/server.crt"
readonly server_ext="$output_dir/server.ext"
readonly server_pem="$output_dir/tls.pem"

openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:3072 -out "$ca_key" >/dev/null 2>&1
chmod 600 -- "$ca_key"
openssl req -x509 -new -sha256 -days 7 -key "$ca_key" -out "$ca_cert" \
  -subj '/CN=DSH HAProxy PoC Test CA' >/dev/null 2>&1
chmod 644 -- "$ca_cert"

openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 -out "$server_key" >/dev/null 2>&1
chmod 600 -- "$server_key"
openssl req -new -sha256 -key "$server_key" -out "$server_csr" \
  -subj '/CN=DSH HAProxy PoC LAN IP' >/dev/null 2>&1
{
  printf 'subjectAltName=IP:%s\n' "$lan_ip"
  printf '%s\n' 'basicConstraints=critical,CA:FALSE'
  printf '%s\n' 'keyUsage=critical,digitalSignature,keyEncipherment'
  printf '%s\n' 'extendedKeyUsage=serverAuth'
} > "$server_ext"
openssl x509 -req -sha256 -days 2 -in "$server_csr" -CA "$ca_cert" -CAkey "$ca_key" \
  -CAcreateserial -out "$server_cert" -extfile "$server_ext" >/dev/null 2>&1
chmod 644 -- "$server_cert"

cat "$server_cert" "$ca_cert" "$server_key" > "$server_pem"
chmod 600 -- "$server_pem"
rm -f -- "$server_csr" "$server_ext" "$output_dir/ca-cert.srl"
printf 'PASS: disposable offline HAProxy test PKI created under %s\n' "$output_dir"
