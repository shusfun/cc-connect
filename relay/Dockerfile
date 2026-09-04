FROM docker.io/library/node:26.6.0-alpine@sha256:a4fb14143ee24c038c851864fe85fd90f9121abc8fdca3092798bcc02e06b1d8 AS dependencies

ENV COREPACK_NPM_REGISTRY=https://registry.npmmirror.com \
    NPM_CONFIG_REGISTRY=https://registry.npmmirror.com

WORKDIR /workspace
RUN --mount=type=cache,id=remodex-corepack-26.6.0,target=/root/.cache/node/corepack \
    corepack enable && corepack prepare pnpm@11.18.0 --activate
COPY package.json pnpm-lock.yaml pnpm-workspace.yaml .npmrc ./
COPY relay/package.json relay/package.json
RUN --mount=type=cache,id=remodex-pnpm-11.18.0,target=/root/.local/share/pnpm/store \
    pnpm install --frozen-lockfile --prod --filter remodex-relay

FROM docker.io/library/node:26.6.0-alpine@sha256:a4fb14143ee24c038c851864fe85fd90f9121abc8fdca3092798bcc02e06b1d8

ENV NODE_ENV=production \
    PORT=9820 \
    RELAY_BIND_HOST=0.0.0.0 \
    REMODEX_TRUST_PROXY=true

WORKDIR /app
COPY --from=dependencies --chown=10001:10001 /workspace/relay/node_modules ./node_modules
COPY --chown=10001:10001 relay/package.json relay/server.js relay/relay.js ./

USER 10001:10001
EXPOSE 9820
CMD ["node", "server.js"]
