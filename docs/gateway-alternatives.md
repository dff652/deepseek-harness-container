# Gateway alternatives and lightweight relay decision

## Decision

The container appliance needs a same-network-namespace relay, but that relay
does not have to be Caddy. Mature open-source alternatives exist, so this
project must not treat “wait for a new Caddy release” as its only remediation
path and must not start a new proxy implementation before those alternatives
are tested.

The current order is:

1. keep the locked Caddy appliance as the functional baseline;
2. retain the completed isolated HAProxy proof of concept as a
   non-publishing candidate;
3. test NGINX only if HAProxy cannot close the remaining complete security,
   operations and offline-delivery result;
4. retain Traefik as a secondary option, not the first remediation candidate;
5. consider a project-owned relay only if the mature alternatives fail the
   measured acceptance gates.

No alternative in this document is adopted, release-approved or deployable
yet. The HAProxy PoC has selected and tested exact AMD64/ARM64 image children,
but its unresolved scan findings and missing native production-ARM evidence
keep the default Caddy path unchanged.

## The contract an alternative must preserve

Replacing Caddy means replacing all of its current responsibilities, not only
the final `reverse_proxy` statement. A candidate must:

- listen on the deployment-selected LAN IP and approved external HTTPS port
  (443 by default) without a domain;
- present an IP-SAN certificate to clients that omit SNI as well as clients
  that send the literal IP as SNI;
- reject any Host other than the exact deployment authority (`IP` or
  `IP:non-default-port`) with status 421;
- reject `Sec-Fetch-Site: cross-site` with status 403;
- permit an absent `Origin`, but reject a supplied Origin unless it exactly
  matches the deployment authority and port;
- require Basic Auth using a one-way password hash;
- perform those external trust checks before rewriting any upstream header;
- proxy only to DSH at `127.0.0.1:3080` in the shared network namespace;
- set upstream Host to `127.0.0.1:3080` and remove `Origin` and
  `Sec-Fetch-Site` only after the trust gate passes;
- preserve WebSocket, SSE and long streaming responses;
- run non-root with a read-only root filesystem, no shell dependency at
  runtime if practical, only `NET_BIND_SERVICE`, and no Docker socket, host
  networking or port 3080 publication;
- validate configuration before startup and pass the same cold-start,
  401/200/421/403, header, streaming and negative-exposure tests on AMD64 and
  ARM64;
- be delivered by exact digest with actual-image SBOM, vulnerability scan,
  license review, provenance and offline archives.

This contract is derived from the shipped `Caddyfile`, `compose.yaml` and the
request-trust boundary in [architecture.md](architecture.md). A smaller image
or shorter configuration does not compensate for a missing control.

## Open-source alternatives

| Candidate | Relevant verified capability | Gap for this appliance | Current decision |
| --- | --- | --- | --- |
| HAProxy | Ordered HTTP ACL/actions, exact header matching, configurable deny status, Basic Auth userlists, request-header set/delete, PEM TLS certificates and WebSocket support; exact dual-architecture PoC passed locally | No Caddy-style embedded local CA; two unresolved High scan records per architecture; native target acceptance pending | **PoC passed functionally; adoption held** |
| NGINX Open Source | TLS with a default server certificate, Basic Auth, `map`-based request classification, explicit response status, upstream header removal and documented WebSocket tunnelling | External PKI required; the exact trust policy is more verbose and sensitive to configuration ordering | **Second PoC if needed** |
| Traefik Proxy | File-only configuration, Host/Header/HeaderRegexp rules with negation, BasicAuth, request-header removal, user-supplied TLS certificates and a default certificate for no-SNI clients | Exact 421/403 responses require extra router/error-service design; it is another Go proxy, so it may retain the class of compiled Go findings being investigated | **Viable, lower priority** |

HAProxy was the best first comparison because its ordered ACL and
`http-request` model maps directly onto the existing gate. Its official
configuration manual documents declaration-order evaluation, `hdr(Host)`,
Basic Auth through `http_auth`, `deny` with a chosen status, `set-header`,
`del-header`, TLS certificate loading and WebSocket behavior. HAProxy is open
source under GPLv2 with the repository's documented OpenSSL exception.

NGINX is also a credible replacement. Its official modules document
`auth_basic`, TLS certificate loading, `map`, `return`, proxy header rewriting
and WebSocket tunnelling. In particular, a `proxy_set_header` value of an empty
string removes that header from the upstream request. NGINX is open source
under its two-clause BSD-like license. The main drawback here is not missing
proxy functionality; it is the additional policy/configuration surface and
the same external certificate lifecycle required by HAProxy.

Traefik's current documentation confirms the file provider, BasicAuth,
Host/Header/HeaderRegexp matchers (including logical negation), request-header
removal, user-defined certificates and a default certificate for connections
without SNI. It is MIT-licensed. It can represent the allow route, but matching
the current explicit failure statuses cleanly would require additional routing
or an error response service. That extra mechanism must not become an
unreviewed bypass. Because Traefik is also implemented in Go, it is not the
preferred experiment for determining whether moving away from Caddy reduces
the remaining compiled-Go findings.

Official references used for this assessment and PoC:

- [HAProxy 3.4 configuration manual](https://docs.haproxy.org/3.4/configuration.html),
  [management/config validation](https://docs.haproxy.org/3.4/management.html),
  [Docker Official Image record](https://github.com/docker-library/official-images/blob/master/library/haproxy)
  and [HAProxy license](https://github.com/haproxy/haproxy/blob/master/LICENSE);
- [NGINX Basic Auth](https://nginx.org/en/docs/http/ngx_http_auth_basic_module.html),
  [TLS](https://nginx.org/en/docs/http/ngx_http_ssl_module.html),
  [`map`](https://nginx.org/en/docs/http/ngx_http_map_module.html),
  [proxy/header behavior](https://nginx.org/en/docs/http/ngx_http_proxy_module.html),
  [WebSocket proxying](https://nginx.org/en/docs/http/websocket.html) and
  [NGINX license](https://github.com/nginx/nginx/blob/master/LICENSE);
- [Traefik rules and priority](https://doc.traefik.io/traefik/reference/routing-configuration/http/routing/rules-and-priority/),
  [BasicAuth](https://doc.traefik.io/traefik/reference/routing-configuration/http/middlewares/basicauth/),
  [headers](https://doc.traefik.io/traefik/reference/routing-configuration/http/middlewares/headers/),
  [TLS certificates](https://doc.traefik.io/traefik/reference/routing-configuration/http/tls/tls-certificates/)
  and [Traefik license](https://github.com/traefik/traefik/blob/master/LICENSE.md).

These references establish feature feasibility, not acceptance of a container
image or its vulnerability state.

## Offline certificate ownership

Caddy's `tls internal` currently creates and persists a local CA and the
literal-IP server certificate. HAProxy, NGINX and the proposed Traefik profile
instead consume a certificate and private key supplied by the deployment.
Replacing Caddy therefore moves certificate issuance, renewal, key protection
and client trust distribution into an explicit deployment-owned PKI step.

The smallest acceptable design is a one-shot, network-disabled initializer
that receives the deployment IP, creates or reuses a persistent offline CA,
issues an IP-SAN server certificate, writes only the public root plus server
certificate/key volumes, and then exits. The long-running gateway must receive
the server key read-only and must never receive an online registry credential
or the CA root private key if the signer can be kept outside the appliance.

Smallstep documents both IP SANs and offline certificate issuance with
`step ca certificate --offline`; its client documentation also makes the
necessary root-CA trust bootstrap explicit. It is one possible implementation,
not an adopted dependency. OpenSSL or another reviewed offline PKI tool may be
used only after the same deterministic-output, secret-boundary, expiry and
renewal tests are defined. See the official
[`step ca certificate` reference](https://smallstep.com/docs/step-cli/reference/ca/certificate/)
and [offline CA concepts](https://smallstep.com/docs/step-ca/certificate-authority-core-concepts/).

The absence of a domain does not prevent HTTPS. It means the certificate must
contain the LAN address as an IP SAN and every managed client must trust the
deployment CA. Direct `http://<IP>` or instructing users to ignore TLS errors
is not an accepted fallback.

## Should this project build a lightweight relay?

It is technically feasible, but it is not currently justified. The desired
data path is small; the security ownership is not. A release-quality relay
would become an Internet-protocol security component and must correctly own:

- TLS defaults, no-SNI behavior, IP SAN validation and certificate reload;
- strict Host, Origin and Fetch Metadata parsing, including duplicate and
  malformed headers and IPv6 literal authorities;
- constant-time credential verification and safe log redaction;
- hop-by-hop header handling, request smuggling boundaries and upstream Host
  rewriting;
- WebSocket upgrades, SSE flushing, backpressure, cancellation and graceful
  shutdown;
- header/body limits, slow-client timeouts and resource exhaustion defenses;
- configuration validation, health semantics and stable failure status codes.

A narrow custom design should load a deployment-supplied certificate/key and
CA; it should not implement its own CA in the first version. A single Rust
binary using a reviewed HTTP stack and rustls is the most relevant experiment
if the purpose is to avoid the compiled-Go dependency class. A Go
`net/http`/`ReverseProxy` implementation would be simpler for the team but
would not test that hypothesis. Either choice still creates dependency,
vulnerability, license, fuzzing and long-term maintenance obligations.

The custom track may begin only after an owner records why HAProxy and NGINX
failed the same measured contract. Its minimum gate is:

1. unit and property tests for every allow/deny combination and duplicated or
   malformed authority/security header;
2. differential tests against the accepted Caddy behavior;
3. WebSocket, SSE, large upload, cancellation, timeout and restart tests;
4. parser and request-boundary fuzzing, including HTTP request-smuggling cases;
5. rootless/read-only Compose tests and negative exposure checks;
6. native AMD64 and ARM64 builds with exact locks, SBOM, provenance, licenses
   and actual-binary vulnerability scans;
7. disconnected cold-start and real ARM acceptance before any publication.

Until those gates are warranted and funded, a custom relay would exchange a
known upstream dependency for a larger project-owned security burden.

## Completed PoC and decision gate

The 2026-08-22 non-publishing PoC selected Docker Official Image
`haproxy:3.4.3-alpine3.24` at index
`sha256:fb87fc81943143b9acaea7442973e6ba654035fff76ffe7af6829dd1bcb0f7a5`,
with exact AMD64 child `sha256:c7f5037a…` and ARM64 child
`sha256:0fe6e31a…`. The isolated Compose profile leaves `compose.yaml` and the
default Caddy service unchanged.

Native AMD64 and QEMU ARM64 tests passed non-root/read-only startup, exact
Host and Origin policy for both IP:443 and IP:non-default-port authorities,
cross-site rejection, trusted IP-SAN TLS with and without SNI, Basic Auth
401/200, upstream-header removal, WebSocket, SSE, restart recovery and no
published 3080/UDP. Full Compose tests using the exact DSH AMD64 and ARM64
images also passed. See [the offline PoC runbook](haproxy-poc.md) for exact
digests, commands and evidence boundaries.

Both native build-only workflows contain the isolated tests. AMD64 run
`32664544119` and ARM64 run `32664545874` passed them for source `8b9ce04…`,
including classic-store clean-load for the HAProxy and Caddy archive tags.
This is native CI functional evidence, not retained supply-chain approval or
a gateway adoption decision.

Actual-image scans with Syft `1.51.0`, Grype `0.117.0` and the database built
`2026-08-21T06:17:24Z` found two High records on each HAProxy child, both for
`CVE-2026-14456` in `libcrypto3` and `libssl3`. Combined with DSH's four
records, the comparison is six records per architecture: lower than the
official Caddy and Distroless-Caddy snapshots, but not zero. The official
HAProxy Alpine image also retains a shell/package manager and is not
Distroless.

The HAProxy binary is compiled with QUIC support, but this isolated profile
configures only TCP TLS and publishes no UDP port. That lowers reachability for
`CVE-2026-14456`; it does not approve the two package findings or replace the
required owner/tracking/expiry review. No exception was added.

Adoption requires an improvement in the whole appliance, not merely a lower
scanner count: exact behavioral parity, simpler or acceptable offline PKI,
maintainable dual-architecture delivery, and zero unapproved High/Critical
findings under the existing fail-closed policy. The remaining HAProxy work is
native retained supply-chain evidence, real disconnected ARM/browser/model/MCP
and cold-boot acceptance, then an explicit gateway-selection decision. NGINX
or a custom relay is not justified while HAProxy remains a viable held
candidate. Commit, push, image publication, release and production deployment
remain separate approvals.
