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
test "$(docker run --rm --network none "$IMAGE_REF" --version)" = '0.1.1-rc.1'
docker run --rm \
  --network none \
  --tmpfs /tmp:rw,noexec,nosuid,nodev,size=64m \
  --entrypoint node \
  "$IMAGE_REF" \
  -e '
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
  if docker exec "$CONTAINER_NAME" node -e \
    "fetch('http://127.0.0.1:3080/').then(r=>process.exit(r.ok?0:1)).catch(()=>process.exit(1))"; then
    break
  fi
  if [[ "$attempt" -eq 30 ]]; then
    docker logs "$CONTAINER_NAME" >&2
    exit 1
  fi
  sleep 1
done

test "$(docker exec "$CONTAINER_NAME" id -u)" = '10001'
test -z "$(docker port "$CONTAINER_NAME")"
printf 'PASS: amd64 DSH runtime version, loopback Web and non-root boundary\n'
