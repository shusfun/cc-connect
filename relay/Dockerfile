FROM docker.io/library/node:26.6.0-alpine@sha256:a4fb14143ee24c038c851864fe85fd90f9121abc8fdca3092798bcc02e06b1d8 AS dependencies

ENV NPM_CONFIG_REGISTRY=https://registry.npmmirror.com

WORKDIR /workspace
RUN --mount=type=cache,id=remodex-npm-26.6.0,target=/root/.npm \
    npm install --global pnpm@11.18.0 --ignore-scripts
COPY package.json pnpm-lock.yaml pnpm-workspace.yaml .npmrc ./
COPY relay/package.json relay/package.json
COPY packages/protocol/package.json packages/protocol/package.json
COPY packages/updater/package.json packages/updater/package.json
COPY apps/control/package.json apps/control/package.json
RUN --mount=type=cache,id=remodex-pnpm-11.18.0,target=/root/.local/share/pnpm/store \
    pnpm install --frozen-lockfile --ignore-scripts --filter remodex-relay --filter @remodex/updater --filter @remodex/control
COPY packages/protocol/ packages/protocol/
COPY relay/ relay/
COPY packages/updater/ packages/updater/
COPY apps/control/ apps/control/
COPY phodex-bridge/src/secure-transport.js phodex-bridge/src/secure-device-state.js phodex-bridge/src/
RUN pnpm --filter @remodex/control run build && pnpm --filter @remodex/control test && pnpm --filter remodex-relay test && pnpm --filter @remodex/updater test
RUN pnpm --filter remodex-relay deploy --legacy --prod /out/relay && pnpm --filter @remodex/updater deploy --legacy --prod /out/updater

FROM docker.io/library/node:26.6.0-alpine@sha256:a4fb14143ee24c038c851864fe85fd90f9121abc8fdca3092798bcc02e06b1d8 AS runtime
ARG RELEASE_VERSION=0.5.0-alpha.1
ARG SOURCE_SHA=development
LABEL org.opencontainers.image.version=$RELEASE_VERSION org.opencontainers.image.revision=$SOURCE_SHA
ENV REMODEX_RELEASE_VERSION=$RELEASE_VERSION
WORKDIR /app
COPY package.json ./package.json

FROM runtime AS updater
COPY --from=dependencies /out/updater ./packages/updater
CMD ["node", "packages/updater/server.js"]

FROM runtime AS relay

ENV NODE_ENV=production \
    PORT=9820 \
    RELAY_BIND_HOST=0.0.0.0 \
    REMODEX_TRUST_PROXY=true

WORKDIR /app
COPY --from=dependencies --chown=10001:10001 /out/relay ./relay
RUN mkdir -p /data && chown 10001:10001 /data

USER 10001:10001
EXPOSE 9820
CMD ["node", "relay/server.js"]
