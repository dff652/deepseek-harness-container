# Python SDK deployment evaluation

## Decision

The Python SDK is the simpler carrier for a headless Python application,
scheduled job or programmatic Agent service. It does not replace the Web
appliance required for browser access from multiple LAN devices.

Keep two explicit products instead of mixing their claims:

| Profile | Interface | Best fit | LAN gateway |
|---|---|---|---|
| Web appliance | DSH Web UI over HTTP | interactive browser, settings, sessions and managed LAN users | same-namespace Caddy is required by this design |
| Python headless worker | Python API driving JSON-RPC over subprocess stdio | Python applications, automation, batch work and service integration | none by default; a separately designed API is required for remote clients |

Wrapping the SDK in a new FastAPI/Flask service would create a new API,
authentication, authorization, tenancy, streaming and lifecycle product. It is
not a shortcut to the existing DSH Web UI and is outside the first Web
appliance candidate.

## Why the SDK can simplify ARM64 offline delivery

`deepseek-harness-sdk` launches the exact same-version
`deepseek-harness-runtime-bin` wheel as a subprocess and speaks JSON-RPC over
stdio. The production runtime wheel contains a single-file Node executable and
its target-native ripgrep sidecar, so the target does not need a separate Node
or pnpm installation.

The recorded Python SDK evidence is still the historical rc.1 release and was
not upgraded or revalidated as part of the Web appliance's rc.2 update. It uses
PEP 440 version `0.1.1rc1`; the 2026-08-21 PyPI snapshot carried:

| Artifact | SHA-256 | Size |
|---|---|---:|
| `deepseek_harness_sdk-0.1.1rc1-py3-none-any.whl` | `2113aec229039da435bc44b275b487216d2b1c308d850521b88cea6ce3c1b762` | 12,878 bytes |
| `deepseek_harness_runtime_bin-0.1.1rc1-py3-none-manylinux_2_28_aarch64.whl` | `e73987c6c08d8322bce2b8b2ce75db6a139ecf546417b6015ce7a8de5e5f19b5` | 59,810,637 bytes |

Those hashes were read from PyPI metadata on 2026-08-21. An offline bundle
must also include the SDK's locked Python dependency closure, hashes and wheel
license/provenance records; copying only these two wheels is not a complete
installation.

## Capability differences

The bundled SDK configuration includes the JSON-RPC server, Agent core,
DeepSeek adapter, JSONL persistence, local bash and filesystem behavior. It
also includes the DSH MCP client. External stdio MCP executables, HTTP MCP
services, credentials and custom Cordis configuration remain deployment-owned.
MCP Tools are supported; the runtime documentation states that MCP Resources
and Prompts are not.

The Python carrier does not boot the Web profile or provide its browser UI,
settings pages, Caddy ingress or browser request-trust layer. Its trust boundary
is the parent Python process, subprocess environment, working/session roots and
the selected Cordis configuration.

## Offline headless proof required

Before adding a `python-worker` image target, prove on real ARM64:

1. install all wheels from a hashed local wheelhouse with index access disabled;
2. import `deepseek_harness` and resolve the bundled aarch64 runtime;
3. start and stop the subprocess without a system Node installation;
4. run one local/mock request, one real approved model request and one MCP tool;
5. verify `DSH_CWD` and `DSH_SESSION_ROOT` write boundaries;
6. verify timeout, child cleanup, provider failure and restart behavior;
7. confirm the container has no Web listener unless the deployment explicitly
   adds a separately reviewed API.

Until those gates pass, Python SDK support remains an evaluated optional
profile, not part of the Web appliance release.

## Upstream references

- [Python SDK guide](https://deepseek-harness.github.io/deepseek-harness/guide/python-sdk)
- [Python SDK README at rc.1](https://raw.githubusercontent.com/deepseek-ai/deepseek-harness/dsh-v0.1.1-rc.1/python/sdk/README.md)
- [Runtime wheel design at rc.1](https://raw.githubusercontent.com/deepseek-ai/deepseek-harness/dsh-v0.1.1-rc.1/python/sdk-runtime/README.md)
- [Python release workflow](https://github.com/deepseek-ai/deepseek-harness/blob/dsh-v0.1.1-rc.1/python/development.md)
