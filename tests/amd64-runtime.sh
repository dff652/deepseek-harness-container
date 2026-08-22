#!/usr/bin/env bash
set -Eeuo pipefail

readonly IMAGE_REF=${1:?usage: amd64-runtime.sh IMAGE_REF}
readonly CONTAINER_NAME="dsh-amd64-smoke-${$}-${RANDOM}"
readonly LABEL='io.deepseek-harness-container.test=amd64-runtime'

cleanup() {
  if docker container inspect "$CONTAINER_NAME" >/dev/null 2>&1; then
    test "$(docker container inspect "$CONTAINER_NAME" \
      --format '{{index .Config.Labels "io.deepseek-harness-container.test"}}')" = \
      'amd64-runtime'
    docker container rm --force "$CONTAINER_NAME" >/dev/null
  fi
}
trap cleanup EXIT

test "$(docker image inspect "$IMAGE_REF" --format '{{.Os}}/{{.Architecture}}')" = \
  'linux/amd64'
test "$(docker run --rm --network none --entrypoint /nodejs/bin/node "$IMAGE_REF" --version)" = 'v24.19.0'
test "$(docker run --rm --network none "$IMAGE_REF" --version)" = '0.1.1-rc.1'
docker run --rm \
  --network none \
  --tmpfs /tmp:rw,noexec,nosuid,nodev,size=64m \
  --entrypoint /nodejs/bin/node \
  "$IMAGE_REF" \
  -e '
    const fs = require("node:fs");
    const forbidden = [
      "/bin/sh", "/bin/bash", "/usr/bin/npm", "/usr/bin/npx",
      "/usr/local/bin/npm", "/usr/local/bin/npx", "/opt/corepack",
      "/opt/yarn-v1.22.22", "/pnpm", "/usr/local/lib/node_modules/corepack",
      "/usr/local/lib/node_modules/npm",
    ];
    for (const path of forbidden) {
      if (fs.existsSync(path)) throw new Error(`unexpected production path: ${path}`);
    }
    for (const path of ["/var/lib/dsh", "/workspace"]) {
      const stat = fs.statSync(path);
      if (stat.uid !== 10001 || stat.gid !== 10001) {
        throw new Error(`unexpected ownership on ${path}: ${stat.uid}:${stat.gid}`);
      }
    }
    const root = "/opt/dsh/runtime/node_modules/.pnpm/";
    const modules = [
      ["koffi", root + "koffi@3.1.6/node_modules/koffi"],
      ["node-pty", root + "node-pty@1.2.0-beta.15/node_modules/node-pty"],
      ["landlock", root + "@deepseek-ai+node-addon-landlock-run@0.1.1/node_modules/@deepseek-ai/node-addon-landlock-run"],
      ["sharp", root + "sharp@0.35.3/node_modules/sharp"],
    ];
    for (const [name, path] of modules) {
      const value = require(path);
      if (!value) throw new Error(`${name} did not load`);
    }
    if (process.getuid() !== 10001) throw new Error(`unexpected uid: ${process.getuid()}`);
  '

docker run --detach \
  --name "$CONTAINER_NAME" \
  --label "$LABEL" \
  --network none \
  --read-only \
  --cap-drop ALL \
  --security-opt no-new-privileges:true \
  --tmpfs /tmp:rw,noexec,nosuid,nodev,size=64m \
  --tmpfs /var/lib/dsh:rw,nosuid,nodev,size=64m,uid=10001,gid=10001 \
  "$IMAGE_REF" >/dev/null

for attempt in $(seq 1 30); do
  if docker exec "$CONTAINER_NAME" /nodejs/bin/node -e \
    "fetch('http://127.0.0.1:3080/').then(r=>process.exit(r.ok?0:1)).catch(()=>process.exit(1))"; then
    break
  fi
  if [[ "$attempt" -eq 30 ]]; then
    docker logs "$CONTAINER_NAME" >&2
    exit 1
  fi
  sleep 1
done

test "$(docker exec "$CONTAINER_NAME" /nodejs/bin/node -p 'process.getuid()')" = '10001'
test -z "$(docker port "$CONTAINER_NAME")"
printf 'PASS: amd64 distroless DSH runtime, native modules, no shell/package manager, loopback Web and non-root boundary\n'
