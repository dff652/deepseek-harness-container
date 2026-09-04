# syntax=docker/dockerfile:1.7@sha256:a57df69d0ea827fb7266491f2813635de6f17269be881f696fbfdf2d83dda33e

# ARM64 remains the release target and default. Local amd64 validation passes
# its own immutable child manifest explicitly; neither path resolves a floating
# multi-platform tag during the build.
ARG TARGETPLATFORM=linux/arm64
ARG NODE_BASE_REF=node:24.19.0-bookworm-slim@sha256:c133efe216ffb6e785ed9a8be55a29fcb86775e8008ae0a9f0ed6af4f175bb03
ARG NODE_RUNTIME_REF=gcr.io/distroless/nodejs24-debian13@sha256:8f5b4fe36a991614a46469e4ec06f65838a2bc22d61f560aac9d40ae62e9ac5a
FROM --platform=${TARGETPLATFORM} ${NODE_BASE_REF} AS base

ENV COREPACK_HOME=/opt/corepack \
    PNPM_HOME=/pnpm \
    PATH=/pnpm:/opt/dsh/runtime/node_modules/.bin:${PATH} \
    CI=true

WORKDIR /opt/dsh/runtime

# Corepack resolves the exact packageManager entry (including its integrity
# hash) from the project manifest rather than installing an unverified global
# package-manager download.
COPY runtime/package.json ./package.json
RUN corepack enable \
 && test "$(pnpm --version)" = "11.7.0"

# Empty named volumes inherit ownership from these image paths on first use.
# Create them in a shell-capable stage, then copy only the directories into the
# shell-less production stage.
RUN install --directory --owner=10001 --group=10001 \
      /dsh-runtime-root/var/lib/dsh /dsh-runtime-root/workspace

FROM base AS dependency-store

COPY runtime/pnpm-lock.yaml runtime/pnpm-workspace.yaml ./
# Registry access is confined to this stage. Slow preparation networks get a
# bounded retry window without changing any version, integrity or policy lock.
RUN pnpm fetch --prod --frozen-lockfile

FROM base AS build

COPY --from=dependency-store /pnpm /pnpm
COPY runtime/pnpm-lock.yaml runtime/pnpm-workspace.yaml ./
# The networked fetch stage already applies pnpm's registry-backed policy pass.
# This stage trusts that reviewed lockfile so --offline performs no metadata
# request, then runs only the explicit allowBuilds entries. Native packages
# must resolve their integrity-locked ARM64 prebuilds: there is no floating
# Debian compiler fallback.
RUN pnpm --config.trust-lockfile=true install --prod --frozen-lockfile --offline

# One-shot plugin administration keeps the package manager and the exact DSH
# dependency closure available for offline tarball installs. This target is
# separate from, and is never copied into, the shell-less production runtime.
FROM build AS plugin-admin

LABEL org.opencontainers.image.title="DeepSeek Harness plugin administrator" \
      org.opencontainers.image.version="0.1.1-rc.2" \
      org.opencontainers.image.vendor="deepseek-harness-container"

RUN groupadd --gid 10001 dsh \
 && useradd --uid 10001 --gid 10001 --home-dir /var/lib/dsh \
      --create-home --shell /usr/sbin/nologin dsh \
 && install --directory --owner=10001 --group=10001 \
      /var/lib/dsh /evidence /inputs /workspace \
 && install --directory /opt/pnpm-bin \
 && ln -s /opt/corepack/v1/pnpm/11.7.0/bin/pnpm.mjs /opt/pnpm-bin/pnpm \
 && test "$(/opt/pnpm-bin/pnpm --version)" = "11.7.0"

COPY --chown=10001:10001 scripts/plugin-admin.sh /usr/local/bin/plugin-admin.sh
RUN chmod 0755 /usr/local/bin/plugin-admin.sh

ENV NODE_ENV=production \
    HOME=/var/lib/dsh \
    DSH_HOME=/var/lib/dsh \
    PNPM_CONFIG_OFFLINE=true \
    PNPM_CONFIG_IGNORE_SCRIPTS=true \
    PNPM_CONFIG_STORE_DIR=/var/lib/dsh/.pnpm-store \
    PATH=/opt/pnpm-bin:/opt/dsh/runtime/node_modules/.bin:${PATH}

WORKDIR /workspace
USER 10001:10001
STOPSIGNAL SIGTERM
ENTRYPOINT ["/usr/local/bin/plugin-admin.sh"]

FROM --platform=${TARGETPLATFORM} ${NODE_RUNTIME_REF} AS runtime

LABEL org.opencontainers.image.title="DeepSeek Harness runtime" \
      org.opencontainers.image.version="0.1.1-rc.2" \
      org.opencontainers.image.vendor="deepseek-harness-container" \
      org.opencontainers.image.source="https://github.com/deepseek-ai/deepseek-harness"

# The production image copies only the installed application into a pinned
# shell-less Node runtime. Build/package managers and Debian essential tooling
# remain in the build and development stages and never enter this filesystem.

COPY --from=base --chown=10001:10001 /dsh-runtime-root/var/lib/dsh/ /var/lib/dsh/
COPY --from=base --chown=10001:10001 /dsh-runtime-root/workspace/ /workspace/
WORKDIR /opt/dsh/runtime
COPY --from=build --chown=10001:10001 /opt/dsh/runtime/package.json ./package.json
COPY --from=build --chown=10001:10001 /opt/dsh/runtime/pnpm-lock.yaml ./pnpm-lock.yaml
COPY --from=build --chown=10001:10001 /opt/dsh/runtime/node_modules ./node_modules

ENV NODE_ENV=production \
    HOME=/var/lib/dsh \
    DSH_HOME=/var/lib/dsh \
    PATH=/opt/dsh/runtime/node_modules/.bin:/nodejs/bin

WORKDIR /workspace
USER 10001:10001
STOPSIGNAL SIGTERM

# DSH's HMR loader requires Node internals. Calling the exact installed module
# with the explicit Node flag avoids an amd64 startup race in the native-addon
# fallback; runtime startup still never invokes npx, npm, pnpm or a download.
ENTRYPOINT ["/nodejs/bin/node", "--expose-internals", "/opt/dsh/runtime/node_modules/@deepseek-ai/dsh/lib/bin.js"]
CMD ["web", "--host", "127.0.0.1", "--port", "3080", "--no-open"]

FROM build AS dev-runtime

LABEL org.opencontainers.image.title="DeepSeek Harness development runtime" \
      org.opencontainers.image.version="0.1.1-rc.2" \
      org.opencontainers.image.vendor="deepseek-harness-container"

RUN groupadd --gid 10001 dsh \
 && useradd --uid 10001 --gid 10001 --home-dir /var/lib/dsh --create-home \
      --shell /bin/bash dsh \
 && install --directory --owner=10001 --group=10001 /var/lib/dsh /workspace

ENV NODE_ENV=development \
    HOME=/var/lib/dsh \
    DSH_HOME=/var/lib/dsh

WORKDIR /workspace
USER 10001:10001
STOPSIGNAL SIGTERM
ENTRYPOINT ["node", "--expose-internals", "/opt/dsh/runtime/node_modules/@deepseek-ai/dsh/lib/bin.js"]
CMD ["web", "--host", "127.0.0.1", "--port", "3080", "--no-open"]
