// FILE: server.js
// Purpose: Hosts the public Remodex rendezvous and encrypted WebSocket relay.
// Layer: Standalone server entrypoint
// Exports: createRelayServer, createFixedWindowRateLimiter
// Depends on: http, ws, ./relay

const http = require("http");
const { createHmac, randomBytes } = require("crypto");
const { monitorEventLoopDelay } = require("perf_hooks");
const { WebSocketServer } = require("ws");
const {
  setupRelay,
  getRelayStats,
  resolvePairingCode,
  resolveTrustedMacSession,
} = require("./relay");

const relayLogIdentitySecret = randomBytes(32);
const allowUpgrade = () => null;
function rejectRelayUpgrade(socket, status, code) {
  const requestId = require('node:crypto').randomUUID();
  console.info(JSON.stringify({ route: 'relay/upgrade', stage: 'authorization', status, code, requestId, result: 'rejected' }));
  socket.end(`HTTP/1.1 ${status} Rejected\r\nConnection: close\r\nCache-Control: no-store\r\nx-remodex-request-id: ${requestId}\r\nx-remodex-error: ${code}\r\n${status === 429 ? 'Retry-After: 60\r\n' : ''}\r\n`);
}

function createRelayServer({
  exposeDetailedHealth = false,
  httpRateLimiter = createFixedWindowRateLimiter({ windowMs: 60_000, maxRequests: 120 }),
  upgradeRateLimiter = createFixedWindowRateLimiter({ windowMs: 60_000, maxRequests: 60 }),
  relayOptions = {},
  trustProxy = false,
  accessControl = null,
  authorizeUpgrade = allowUpgrade,
} = {}) {
  const runtimeMetrics = createRuntimeMetrics();

  const server = http.createServer((req, res) => {
    void (async () => {
      if (accessControl && await accessControl.route(req, res)) return;
      const pathname = safePathname(req.url);
      if (accessControl && (pathname.includes('/v1/trusted/') || pathname.includes('/v1/pairing/'))) {
        return writeJSON(res, 426, { ok: false, code: 'update_required' });
      }
      await handleHTTPRequest(req, res, {
      exposeDetailedHealth,
      httpRateLimiter,
      runtimeMetrics,
      trustProxy,
      });
    })().catch(() => {
      if (!res.headersSent) writeJSON(res, 500, { ok: false, code: 'internal_error' });
      else res.destroy();
    });
  });
  const wss = new WebSocketServer({
    noServer: true,
    perMessageDeflate: true,
  });
  setupRelay(wss, relayOptions);

  server.on("upgrade", (req, socket, head) => {
    const pathname = safePathname(req.url);
    const role = readUpgradeRole(req);
    console.log(`[relay] upgrade request path=${pathname.startsWith('/relay/') ? '/relay/[session]' : '[invalid]'} remote=${clientAddressLabel(req, { trustProxy })} role=${['mac','iphone','android'].includes(role) ? role : 'unknown'}`);
    if (!pathname.startsWith("/relay/")) {
      rejectRelayUpgrade(socket, 404, 'invalid_relay_path');
      return;
    }

    if (!upgradeRateLimiter.allow(clientAddressKey(req, { trustProxy }))) {
      rejectRelayUpgrade(socket, 429, 'rate_limited');
      return;
    }

    try {
      req.remodexAccess = accessControl ? accessControl.authorizeUpgrade(req) : authorizeUpgrade(req);
    } catch (error) {
      const status = [400,401,403,410,429,503].includes(error.status) ? error.status : 401;
      const code = error.status && /^[a-z][a-z_]{0,63}$/.test(error.code || '') ? error.code : 'access_denied';
      rejectRelayUpgrade(socket, status, code);
      return;
    }
    wss.handleUpgrade(req, socket, head, (ws) => {
      if (accessControl) accessControl.attach(ws, req);
      wss.emit("connection", ws, req);
    });
  });

  return {
    server,
    wss,
  };
}

async function handleHTTPRequest(req, res, {
  exposeDetailedHealth,
  httpRateLimiter,
  runtimeMetrics,
  trustProxy,
}) {
  const pathname = safePathname(req.url);
  if (req.method === "GET" && pathname === "/health") {
    return writeJSON(
      res,
      200,
      exposeDetailedHealth
        ? {
            ok: true,
            relay: getRelayStats(),
            runtime: runtimeMetrics.snapshot(),
          }
        : { ok: true }
    );
  }

  const requestKey = clientAddressKey(req, { trustProxy });
  if (!httpRateLimiter.allow(requestKey)) {
    return writeRateLimitResponse(res);
  }

  if (req.method === "POST" && isRelayHTTPAPIPath(pathname, "/v1/trusted/session/resolve")) {
    return handleJSONRoute(req, res, async (body) => resolveTrustedMacSession(body));
  }

  if (req.method === "POST" && isRelayHTTPAPIPath(pathname, "/v1/pairing/code/resolve")) {
    return handleJSONRoute(req, res, async (body) => resolvePairingCode(body));
  }

  return writeJSON(res, 404, {
    ok: false,
    error: "Not found",
  });
}

async function handleJSONRoute(req, res, handler) {
  try {
    const body = await readJSONBody(req);
    const result = await handler(body);
    return writeJSON(res, 200, result);
  } catch (error) {
    return writeJSON(res, error.status || 500, {
      ok: false,
      error: error.message || "Internal server error",
      code: error.code || "internal_error",
    });
  }
}

function readJSONBody(req) {
  return new Promise((resolve, reject) => {
    const chunks = [];
    let totalSize = 0;

    req.on("data", (chunk) => {
      totalSize += chunk.length;
      if (totalSize > 64 * 1024) {
        reject(Object.assign(new Error("Request body too large"), {
          status: 413,
          code: "body_too_large",
        }));
        req.destroy();
        return;
      }
      chunks.push(chunk);
    });

    req.on("end", () => {
      const rawBody = Buffer.concat(chunks).toString("utf8");
      if (!rawBody.trim()) {
        resolve({});
        return;
      }

      try {
        resolve(JSON.parse(rawBody));
      } catch {
        reject(Object.assign(new Error("Invalid JSON body"), {
          status: 400,
          code: "invalid_json",
        }));
      }
    });

    req.on("error", reject);
  });
}

function writeJSON(res, status, body) {
  res.statusCode = status;
  res.setHeader("content-type", "application/json");
  res.end(JSON.stringify(body));
}

function writeRateLimitResponse(res) {
  res.setHeader("retry-after", "60");
  return writeJSON(res, 429, {
    ok: false,
    error: "Too many requests",
    code: "rate_limited",
  });
}

function isRelayHTTPAPIPath(pathname, routePath) {
  // Supports relays mounted at the domain root or under /relay by a local proxy.
  return pathname === routePath || pathname === `/relay${routePath}`;
}

// Captures process-level pressure that can make WebSocket heartbeats miss deadlines.
function createRuntimeMetrics() {
  const eventLoopDelay = monitorEventLoopDelay({ resolution: 20 });
  eventLoopDelay.enable();
  const startedAt = Date.now();

  return {
    snapshot() {
      const memory = process.memoryUsage();
      return {
        uptimeSeconds: Math.round((Date.now() - startedAt) / 1000),
        eventLoopDelayMs: {
          mean: nanosecondsToMilliseconds(eventLoopDelay.mean),
          max: nanosecondsToMilliseconds(eventLoopDelay.max),
          p99: nanosecondsToMilliseconds(eventLoopDelay.percentile(99)),
        },
        memory: {
          rss: memory.rss,
          heapUsed: memory.heapUsed,
          heapTotal: memory.heapTotal,
          external: memory.external,
        },
      };
    },
  };
}

function nanosecondsToMilliseconds(value) {
  return Number.isFinite(value) ? Math.round(value / 1_000_000) : 0;
}

function safePathname(rawUrl) {
  try {
    return new URL(rawUrl || "/", "http://localhost").pathname;
  } catch {
    return "/";
  }
}

// Hides bearer-like relay session ids from operational logs while preserving route shape.
function redactRelayPathname(pathname) {
  if (typeof pathname !== "string" || !pathname.startsWith("/relay/")) {
    return pathname || "/";
  }

  const [, relayPrefix, ...rest] = pathname.split("/");
  const suffix = rest.length > 1 ? `/${rest.slice(1).join("/")}` : "";
  return `/${relayPrefix}/[session]${suffix}`;
}

// Trust forwarded client IPs only when a known reverse proxy sits in front of the relay.
function clientAddressKey(req, { trustProxy = false } = {}) {
  if (trustProxy) {
    return forwardedClientAddress(req) || req?.socket?.remoteAddress || "unknown";
  }
  return req?.socket?.remoteAddress || "unknown";
}

// Emits a process-local pseudonymous label so logs can correlate abuse without retaining IP addresses.
function clientAddressLabel(
  req,
  { trustProxy = false, secret = relayLogIdentitySecret } = {}
) {
  const address = clientAddressKey(req, { trustProxy });
  const digest = createHmac("sha256", secret).update(address).digest("hex").slice(0, 12);
  return `client#${digest}`;
}

function forwardedClientAddress(req) {
  const xRealIP = readHeaderString(req?.headers?.["x-real-ip"]);
  if (xRealIP) {
    return xRealIP;
  }

  const xForwardedFor = readHeaderString(req?.headers?.["x-forwarded-for"]);
  if (xForwardedFor) {
    const forwardedHops = xForwardedFor
      .split(",")
      .map((value) => value.trim())
      .filter(Boolean);
    const clientHop = forwardedHops[0];
    if (clientHop) {
      return clientHop;
    }
  }

  return "";
}

function readHeaderString(value) {
  const candidate = Array.isArray(value) ? value[0] : value;
  return typeof candidate === "string" && candidate.trim() ? candidate.trim() : "";
}

function readUpgradeRole(req) {
  const headerRole = readHeaderString(req?.headers?.["x-role"]);
  if (headerRole) {
    return headerRole;
  }

  try {
    return readHeaderString(new URL(req?.url || "/", "http://localhost").searchParams.get("role"));
  } catch {
    return "";
  }
}

// Reads an opt-in boolean flag for hosted deployments without changing local/self-host defaults.
function readOptionalBooleanEnv(keys, env = process.env) {
  const truthy = new Set(["1", "true", "yes", "on"]);
  const falsy = new Set(["0", "false", "no", "off"]);

  for (const key of keys) {
    const rawValue = env?.[key];
    if (typeof rawValue !== "string" || !rawValue.trim()) {
      continue;
    }
    const normalizedValue = rawValue.trim().toLowerCase();
    if (truthy.has(normalizedValue)) {
      return true;
    }
    if (falsy.has(normalizedValue)) {
      return false;
    }
  }

  return undefined;
}

function createFixedWindowRateLimiter({ windowMs, maxRequests, now = () => Date.now() } = {}) {
  const buckets = new Map();
  const resolvedWindowMs = Number.isFinite(windowMs) && windowMs > 0 ? windowMs : 60_000;
  const resolvedMaxRequests = Number.isFinite(maxRequests) && maxRequests > 0 ? maxRequests : 60;
  let nextPruneAt = 0;

  return {
    allow(key) {
      const normalizedKey = typeof key === "string" && key.trim() ? key.trim() : "unknown";
      const timestamp = now();
      if (timestamp >= nextPruneAt) {
        nextPruneAt = timestamp + resolvedWindowMs;
        for (const [bucketKey, bucketValue] of buckets.entries()) {
          if (timestamp >= bucketValue.expiresAt) {
            buckets.delete(bucketKey);
          }
        }
      }
      const bucket = buckets.get(normalizedKey);

      if (!bucket || timestamp >= bucket.expiresAt) {
        buckets.set(normalizedKey, {
          count: 1,
          expiresAt: timestamp + resolvedWindowMs,
        });
        return true;
      }

      if (bucket.count >= resolvedMaxRequests) {
        return false;
      }

      bucket.count += 1;
      return true;
    },
    bucketCount() {
      return buckets.size;
    },
  };
}

if (require.main === module) {
  const port = Number(process.env.PORT || 9820);
  const trustProxy = readOptionalBooleanEnv(["REMODEX_TRUST_PROXY", "PHODEX_TRUST_PROXY"]) ?? false;
  const bindHost = process.env.RELAY_BIND_HOST || "127.0.0.1";
  const { createProductionAccess } = require('./production-access');
  const accessControl = createProductionAccess();
  const { server } = createRelayServer({ trustProxy, accessControl });
  server.on('close', () => accessControl.close());
  server.listen(port, bindHost, () => {
    console.log(`[relay] listening on ${bindHost}:${port}`);
  });
}

module.exports = {
  createRelayServer,
  createFixedWindowRateLimiter,
  clientAddressLabel,
  clientAddressKey,
  readOptionalBooleanEnv,
  redactRelayPathname,
};
