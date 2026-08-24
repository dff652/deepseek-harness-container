# HAProxy dual-architecture offline PoC

## Status and boundary

This is an isolated, non-publishing alternative to the default Caddy profile.
It does not modify `compose.yaml`, does not publish DSH port 3080 and does not
authorize a production switch. Local native AMD64 and QEMU ARM64 functional
tests were revalidated on 2026-08-24, including non-default host HTTPS ports
for coexistence with the host installation. A disconnected production ARM host, real browser,
model/MCP calls, cold boot and vulnerability policy acceptance are still
required before adoption.

The native AMD64 and ARM64 build-only workflows include the same isolated
HAProxy contract after building DSH. Source `8b9ce04…` passed native AMD64 run
`32664544119` and native ARM64 run `32664545874`, including clean-load on the
GitHub classic Docker store. The PoC lock still records the earlier retained
scan snapshot and is not a release/adoption approval.

At this snapshot the public GitHub repository has no Actions secrets configured,
the workstation has no `cosign` or signing identity configured, the three
candidate Docker Hub tags are absent, and no Linux production ARM endpoint is
available to this project. These are explicit external gates, not reasons to
weaken the local tests or publish from QEMU evidence.

The PoC uses HAProxy because mature software already implements the required
TLS, authentication, request policy and streaming behavior. It is not a new
project-owned proxy. The Docker Official Image is pinned to:

| Item | Exact identity |
| --- | --- |
| Version/variant | `3.4.3-alpine3.24` |
| OCI index | `sha256:fb87fc81943143b9acaea7442973e6ba654035fff76ffe7af6829dd1bcb0f7a5` |
| AMD64 child | `sha256:c7f5037a567378929d0aba734eb78b73497209c72456519420ce5e68a42d60ac` |
| ARM64 child | `sha256:0fe6e31a91ad42440ceba4419694189673f9773f90b985bd883db0054a7c5259` |
| Docker-library source revision | `40955df2217f5cb77f861e709b239cedd43ff613` |

The tag is never sufficient for offline delivery: select the child matching
`DSH_PLATFORM`, save that exact reference and verify the archive checksum.
This PoC deliberately supports IPv4 only; the current Compose short port
syntax and Host-policy tests do not claim an accepted IPv6 literal profile.

## Implemented topology

`compose.haproxy.yaml` keeps DSH at `127.0.0.1:3080`. HAProxy joins the DSH
network namespace and owns only the approved
`${DSH_LAN_IP}:${DSH_HTTPS_PORT}` host entry while listening on container 443.
A network-disabled, one-shot root initializer copies the deployment-owned
mode-0600 configuration and PEM into a named volume as UID/GID 99 with mode
0440. The long-running
HAProxy process is UID/GID 99, has a read-only root filesystem and receives
only `NET_BIND_SERVICE`; DSH remains UID/GID 10001 with no host-published 3080.

The renderer derives one exact browser authority from `DSH_LAN_IP` and
`DSH_HTTPS_PORT`: bare IP for 443, or IP:port for a non-default port such as
8443. The rendered configuration performs, in order:

1. exact literal-IP Host validation, returning 421 for anything else;
2. cross-site Fetch Metadata and supplied-Origin validation, returning 403;
3. Basic Auth using a SHA-256 crypt hash;
4. upstream Host rewriting and Origin/Fetch-Metadata removal;
5. loopback proxying with WebSocket/SSE tunnel timeouts.

HAProxy does not provide Caddy's `tls internal`. The deployment owner must
issue an IP-SAN certificate, protect the offline CA key and distribute only the
root certificate to managed clients. `scripts/haproxy-test-pki.sh` creates a
short-lived disposable test CA and must never issue production certificates.

## Connected preparation machine

Choose one child reference:

```sh
# AMD64
export HAPROXY_IMAGE='haproxy:3.4.3-alpine3.24@sha256:c7f5037a567378929d0aba734eb78b73497209c72456519420ce5e68a42d60ac'

# ARM64
export HAPROXY_IMAGE='haproxy:3.4.3-alpine3.24@sha256:0fe6e31a91ad42440ceba4419694189673f9773f90b985bd883db0054a7c5259'
```

Pull for the selected architecture, save it beside the already generated DSH
archive and record checksums:

```sh
docker pull --platform linux/arm64 "$HAPROXY_IMAGE"
export HAPROXY_ARCHIVE_TAG='haproxy:dsh-offline-3.4.3-arm64-0fe6e31a91ad'
scripts/save-pinned-image.sh "$HAPROXY_IMAGE" linux/arm64 \
  "$HAPROXY_ARCHIVE_TAG" haproxy-3.4.3-arm64.tar
sha256sum haproxy-3.4.3-arm64.tar > haproxy-3.4.3-arm64.tar.sha256
```

Directly saving the digest-qualified source is prohibited because Docker may
write `RepoTags:null`; a clean disconnected daemon would then load the layers
but fail to resolve the Compose image name. The helper retains one dedicated
same-repository RepoTag. With a containerd image store it verifies the selected
child manifest and subject-linked attachments; with the classic store it
verifies the legacy config blob against the digest-selected source image ID.
In both cases the archive SHA, platform and tag are required evidence. The
AMD64 archive tag is `haproxy:dsh-offline-3.4.3-amd64-c7f5037a5673`.

Use the organization's offline CA to issue a server certificate whose SAN is
the exact LAN IP. Assemble `tls.pem` as server certificate, intermediate chain
if present, then private key; keep it mode 0600. Copy
`.env.haproxy.example` to a deployment-owned path outside Git and fill the
verified offline image tag, platform, LAN IP, approved workspace, rendered
config and PEM paths.

Generate the HAProxy password hash interactively on a trusted preparation
machine; do not put the plaintext password on a command line:

```sh
export DSH_HAPROXY_USERNAME=dsh-admin
hash_salt="$(openssl rand -hex 8)"
export DSH_HAPROXY_PASSWORD_HASH="$(openssl passwd -5 -salt "rounds=1000\$$hash_salt")"
unset hash_salt
export DSH_LAN_IP=192.0.2.10
export DSH_HTTPS_PORT=8443 # use 443 when this is the only HTTPS appliance
python3 scripts/render-haproxy-config.py --output /approved/path/haproxy.cfg
chmod 600 /approved/path/haproxy.cfg /approved/path/tls.pem
```

The example address is documentation-only. HAProxy warns that deliberately
expensive password hashes can become a per-request CPU denial of service. The
PoC starts at the SHA-256 crypt minimum of 1000 rounds for low-power ARM, so
use a high-entropy password, apply LAN/firewall rate controls and load-test the
target. Raise the rounds only when `haproxy -c` with `zero-warning` and the
authentication load test both pass. Plaintext `insecure-password` entries are
prohibited.

Validate without starting the appliance:

```sh
docker compose --env-file /approved/path/haproxy.env \
  --file compose.haproxy.yaml config >/dev/null

# Exercise the same protected staging boundary as deployment. The host files
# stay 0600; only this disposable Docker volume receives UID-99-readable copies.
docker compose --project-name dsh-haproxy-validate \
  --env-file /approved/path/haproxy.env \
  --file compose.haproxy.yaml run --rm --no-deps haproxy-init
docker run --rm --user 99:99 --read-only --cap-drop ALL \
  --security-opt no-new-privileges:true \
  --mount type=volume,src=dsh-haproxy-validate_haproxy-runtime,dst=/run/haproxy,ro \
  --entrypoint haproxy "$HAPROXY_IMAGE" \
  -c -f /run/haproxy/haproxy.cfg
docker compose --project-name dsh-haproxy-validate \
  --env-file /approved/path/haproxy.env \
  --file compose.haproxy.yaml down --volumes --remove-orphans
```

## Disconnected target

Transfer the DSH and HAProxy archives, their checksum files, the Compose file,
rendered config, server PEM and public CA certificate through the approved
offline channel. On the target:

```sh
sha256sum --check SHA256SUMS
sha256sum --check haproxy-3.4.3-arm64.tar.sha256
docker load --input dsh-0.1.1-rc.2-arm64.tar
docker load --input haproxy-3.4.3-arm64.tar
export HAPROXY_IMAGE='haproxy:dsh-offline-3.4.3-arm64-0fe6e31a91ad'
test "$(docker image inspect "$HAPROXY_IMAGE" \
  --format '{{.Os}}/{{.Architecture}}')" = 'linux/arm64'
loaded_id=$(docker image inspect "$HAPROXY_IMAGE" --format '{{.Id}}')
case "$loaded_id" in
  sha256:0fe6e31a91ad42440ceba4419694189673f9773f90b985bd883db0054a7c5259|\
  sha256:5d297f7ef0f6351a1c848101fcb2452cb3f1ae9bfa067f40e94032d499676ef0) ;;
  *) echo "unexpected HAProxy image ID: $loaded_id" >&2; exit 1 ;;
esac
unset loaded_id

docker compose --project-name dsh-haproxy \
  --env-file /approved/path/haproxy.env \
  --file compose.haproxy.yaml up --detach --wait --no-build --pull never
```

Verify the listener and authenticated path with the public CA certificate:

```sh
docker compose --project-name dsh-haproxy \
  --env-file /approved/path/haproxy.env \
  --file compose.haproxy.yaml ps
curl --cacert /approved/path/ca.crt -o /dev/null -w '%{http_code}\n' \
  https://192.0.2.10/                     # expected 401
curl --cacert /approved/path/ca.crt -u dsh-admin \
  -o /dev/null -w '%{http_code}\n' https://192.0.2.10/  # expected 200
docker ps --format '{{.Names}} {{.Ports}}' # must not contain 3080->
```

Import the same public CA into every managed browser/device trust store. Do
not use `curl -k`, browser warning bypasses, raw HTTP or direct port 3080.

## Reproducible local tests

The repository provides three levels:

```sh
./tests/haproxy-contract.sh
./tests/haproxy-runtime.sh
DSH_IMAGE=local/dsh:0.1.1-rc.2-amd64 DSH_PLATFORM=linux/amd64 \
  ./tests/haproxy-compose-runtime.sh
```

For QEMU ARM64, set the exact ARM64 HAProxy child, `DSH_PLATFORM=linux/arm64`
and the loaded ARM64 DSH image for both `DSH_IMAGE` and `BACKEND_IMAGE`; set
`HAPROXY_PLATFORM` and `BACKEND_PLATFORM` to `linux/arm64` for the direct
runtime test. These tests cover configuration rejection, exact default and
non-default authorities, non-root startup, trusted IP-SAN TLS with and without
SNI, 401/200/421/403, upstream header removal, WebSocket, SSE, restart recovery
and no published 3080/UDP. QEMU evidence is not native production acceptance.

## Supply-chain and adoption hold

Syft `1.51.0` and Grype `0.117.0`, using a database built
`2026-08-21T06:17:24Z`, scanned both exact children. Each architecture produced
two High matches, both `CVE-2026-14456`: one for `libcrypto3@3.5.7-r0` and one
for `libssl3@3.5.7-r0`; no scanner-provided fixed version was recorded. The
official image also contains a shell, apk, BusyBox, socat and dynamic libraries
and is not Distroless.

The local Syft documents contain 25 package artifacts per architecture, but
the HAProxy package itself has no recovered license value and socat's extracted
expression is not a clean SPDX expression. Upstream source licensing is GPLv2
with its documented OpenSSL exception, yet that manual fact does not repair
the generated inventory. Formal license-policy integration therefore remains
pending.

The [OpenSSL advisory](https://www.openssl-library.org/news/vulnerabilities-3.6/)
rates the issue Low and describes unbounded growth in a QUIC server incoming
channel queue. The official HAProxy binary is compiled with QUIC support, but
this PoC configures only a TCP TLS listener and publishes no UDP port. That is
useful reachability evidence, not an exception: an owner must still review and
track both exact scanner records before policy can pass.

HAProxy's [3.4.3 maintenance page](https://www.haproxy.org/bugs/bugs-3.4.3.html)
also records one queued Medium fix for a crash while deleting the first
backend. This static PoC never performs dynamic backend deletion, but the next
3.4.x maintenance release must be evaluated, re-pinned and rescanned rather
than claiming the image is unaffected.

Combined with the four current DSH matches, the comparable appliance has six
High/Critical records per architecture. This is lower than the recorded Caddy
baseline, but it still fails the empty-exception publication policy. Do not
adopt, publish, sign or deploy this profile until both native architectures
produce retained SBOM/provenance/license/scan evidence, every finding is
remediated or exactly approved, and the disconnected real-ARM acceptance
passes. No Docker Hub secret or signing key is required or accepted for this
PoC.

`policy/haproxy-poc-lock.json` records the exact index, child/config digests,
tool/database snapshot and explicit pending gates. Its
`rawEvidenceRetained: false` flag is deliberate: this local diagnostic scan is
not a substitute for retained native workflow evidence.

## Final local review and verification

The 2026-08-22 local review covered the gateway-alternatives commit
and the complete combined worktree. It repaired mode-0600 validation staging,
wrong-port Host acceptance, reusable/symlinkable test-PKI output, wildcard
`0.0.0.0` binding, QEMU password-hash cost, one-minute SSE/agent idle timeouts
and digest-only offline archives for both Caddy and HAProxy.

After those repairs, all shell syntax/ShellCheck, Python/YAML/actionlint,
10 supply-chain policy tests, Compose/negative-exposure/workflow contracts,
Caddy initialization and AMD64/ARM64 archive clean-load contracts passed. The
exact local AMD64 and QEMU ARM64 DSH/HAProxy images then passed direct and full
Compose runtime tests. Native GitHub AMD64 run `32664544119` and ARM64 run
`32664545874` subsequently passed the same DSH/HAProxy functional contract and
classic-store archive clean-load checks. Retained formal supply-chain evidence,
real production ARM and publication/adoption decisions remain pending.
