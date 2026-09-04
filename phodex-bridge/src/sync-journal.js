// FILE: sync-journal.js
// Purpose: 为移动端增量同步维护目录和单任务 revision、幂等事件与 ACK。
// Layer: Bridge-owned private sync protocol

const { createHash } = require("crypto");
const fs = require("fs");
const path = require("path");
const { resolveRemodexStateDir } = require("./daemon-state");

const SYNC_PROTOCOL_VERSION = 1;
const DEFAULT_MAX_EVENTS = 50_000;
const DEFAULT_MAX_AGE_MS = 30 * 24 * 60 * 60 * 1_000;
const DEFAULT_HISTORY_PAGE_SIZE = 5;

function createSyncCoordinator({
  macDeviceId,
  sendCodexRequest,
  stateFilePath = path.join(resolveRemodexStateDir(), "sync-journal.json"),
  now = () => Date.now(),
  maxEvents = DEFAULT_MAX_EVENTS,
  maxAgeMs = DEFAULT_MAX_AGE_MS,
  persist = true,
  setTimeoutFn = setTimeout,
  clearTimeoutFn = clearTimeout,
} = {}) {
  if (typeof sendCodexRequest !== "function") {
    throw new TypeError("sendCodexRequest is required");
  }

  const journal = createRevisionJournal({
    stateFilePath,
    now,
    maxEvents,
    maxAgeMs,
    persist,
    setTimeoutFn,
    clearTimeoutFn,
  });

  function handleRequest(rawMessage, sendResponse, parsedMessage = null) {
    const parsed = parsedMessage || safeParseJSON(rawMessage);
    const method = normalizeString(parsed?.method);
    if (!method.startsWith("sync/")) {
      return false;
    }

    const id = parsed?.id;
    Promise.resolve()
      .then(() => handleMethod(method, parsed?.params || {}))
      .then((result) => {
        if (id != null) {
          sendResponse(JSON.stringify({ id, result }));
        }
      })
      .catch((error) => {
        if (id != null) {
          sendResponse(JSON.stringify({
            id,
            error: {
              code: -32000,
              message: error.userMessage || error.message || "同步请求失败。",
              data: { errorCode: error.errorCode || "sync_failed" },
            },
          }));
        }
      });
    return true;
  }

  async function handleMethod(method, params) {
    switch (method) {
      case "sync/hello":
        return journal.hello({ macDeviceId });
      case "sync/catalog": {
        const response = await sendCodexRequest("thread/list", {
          limit: 100,
          archived: false,
        });
        journal.ingestCatalog(extractThreadRows(response), { authoritative: true });
        return journal.catalogSince(readRevision(params.catalogRevision));
      }
      case "sync/thread/read": {
        const threadId = requireThreadId(params);
        if (params.beforeCursor != null) {
          const response = await sendCodexRequest("thread/turns/list", {
            threadId,
            cursor: normalizeString(params.beforeCursor) || null,
            limit: DEFAULT_HISTORY_PAGE_SIZE,
          });
          return {
            threadId,
            history: response,
            pageSize: DEFAULT_HISTORY_PAGE_SIZE,
          };
        }
        return journal.threadSince(threadId, readRevision(params.threadRevision));
      }
      case "sync/thread/reset": {
        const threadId = requireThreadId(params);
        const response = await sendCodexRequest("thread/turns/list", {
          threadId,
          cursor: null,
          limit: DEFAULT_HISTORY_PAGE_SIZE,
          sortDirection: "desc",
        });
        const descendingTurns = extractTurnRows(response).slice(0, DEFAULT_HISTORY_PAGE_SIZE);
        const recentTurns = descendingTurns.reverse();
        const revision = journal.currentThreadRevision(threadId);
        return {
          threadId,
          revision,
          thread: { id: threadId, turns: recentTurns },
          turns: recentTurns,
          beforeCursor: readNextCursor(response),
          pageSize: DEFAULT_HISTORY_PAGE_SIZE,
          reset: true,
        };
      }
      case "sync/ack":
        return journal.ack(params);
      default:
        throw syncError("sync_method_unknown", `不支持的同步方法：${method}`);
    }
  }

  function observeCodexMessage(rawMessage, parsedMessage = null) {
    const parsed = parsedMessage || safeParseJSON(rawMessage);
    if (!parsed || parsed.id != null) {
      return;
    }
    const method = normalizeString(parsed.method);
    const threadId = readThreadId(parsed.params);
    if (!method || !threadId) {
      return;
    }

    if (method === "thread/archived" || method === "thread/deleted") {
      journal.deleteCatalogThread(threadId, { method, params: parsed.params || {} });
      return;
    }
    if (method === "thread/started" || method === "thread/name/updated" || method === "thread/unarchived") {
      const thread = parsed.params?.thread || { id: threadId, ...parsed.params };
      journal.upsertCatalogThread(thread, { method, params: parsed.params || {} });
    }
    journal.appendThreadEvent(threadId, {
      method,
      params: parsed.params || {},
    }, { eventKey: readStableEventKey(parsed) });
  }

  return {
    flush: journal.flush,
    handleRequest,
    journal,
    observeCodexMessage,
    stop: journal.stop,
  };
}

function createRevisionJournal({
  stateFilePath,
  now = () => Date.now(),
  maxEvents = DEFAULT_MAX_EVENTS,
  maxAgeMs = DEFAULT_MAX_AGE_MS,
  persist = true,
  fsImpl = fs,
  setTimeoutFn = setTimeout,
  clearTimeoutFn = clearTimeout,
} = {}) {
  const state = readState(stateFilePath, fsImpl) || emptyState();
  let persistTimer = null;
  const seenEventKeys = new Set(state.events.map((event) => event.eventKey).filter(Boolean));
  prune();

  function hello({ macDeviceId } = {}) {
    return {
      protocolVersion: SYNC_PROTOCOL_VERSION,
      macDeviceId: normalizeString(macDeviceId),
      catalogRevision: state.catalogRevision,
      catalogJournalLowerBound: lowerBound("catalog"),
      threadJournalLowerBounds: Object.fromEntries(
        Object.keys(state.threadRevisions).map((threadId) => [threadId, lowerBound("thread", threadId)])
      ),
      capabilities: {
        catalogDelta: true,
        threadDelta: true,
        threadReset: true,
        historyCursorPageSize: DEFAULT_HISTORY_PAGE_SIZE,
        acknowledgements: true,
      },
    };
  }

  function ingestCatalog(threads, { authoritative = false } = {}) {
    const found = new Set();
    for (const thread of Array.isArray(threads) ? threads : []) {
      const threadId = readThreadId(thread);
      if (!threadId) {
        continue;
      }
      found.add(threadId);
      upsertCatalogThread(thread, { method: "thread/list" });
    }
    if (authoritative) {
      for (const threadId of Object.keys(state.catalog)) {
        if (!found.has(threadId)) {
          deleteCatalogThread(threadId, { method: "thread/list" });
        }
      }
    }
  }

  function upsertCatalogThread(thread, source = {}) {
    const threadId = readThreadId(thread);
    if (!threadId) {
      return state.catalogRevision;
    }
    const normalizedThread = cloneJSON(thread);
    if (stableJSON(state.catalog[threadId]) === stableJSON(normalizedThread)) {
      return state.catalogRevision;
    }
    state.catalog[threadId] = normalizedThread;
    state.catalogRevision += 1;
    appendEvent({
      scope: "catalog",
      revision: state.catalogRevision,
      op: "upsert",
      threadId,
      payload: normalizedThread,
      eventKey: catalogEventKey("upsert", threadId, normalizedThread, source),
    });
    return state.catalogRevision;
  }

  function deleteCatalogThread(threadId, source = {}) {
    const normalizedThreadId = normalizeString(threadId);
    if (!normalizedThreadId || !state.catalog[normalizedThreadId]) {
      return state.catalogRevision;
    }
    delete state.catalog[normalizedThreadId];
    state.catalogRevision += 1;
    appendEvent({
      scope: "catalog",
      revision: state.catalogRevision,
      op: "delete",
      threadId: normalizedThreadId,
      payload: null,
      eventKey: catalogEventKey("delete", normalizedThreadId, null, source),
    });
    return state.catalogRevision;
  }

  function appendThreadEvent(threadId, payload, { eventKey = "" } = {}) {
    const normalizedThreadId = normalizeString(threadId);
    if (!normalizedThreadId) {
      throw syncError("thread_id_required", "同步事件缺少 threadId。 ");
    }
    const normalizedEventKey = normalizeString(eventKey);
    const scopedEventKey = normalizedEventKey ? `thread:${normalizedThreadId}:${normalizedEventKey}` : "";
    if (scopedEventKey && seenEventKeys.has(scopedEventKey)) {
      return currentThreadRevision(normalizedThreadId);
    }
    const revision = currentThreadRevision(normalizedThreadId) + 1;
    state.threadRevisions[normalizedThreadId] = revision;
    appendEvent({
      scope: "thread",
      threadId: normalizedThreadId,
      revision,
      op: "event",
      payload: cloneJSON(payload),
      eventKey: scopedEventKey,
    });
    return revision;
  }

  function catalogSince(revision) {
    const fromRevision = readRevision(revision);
    const journalLowerBound = lowerBound("catalog");
    const gap = fromRevision < journalLowerBound || fromRevision > state.catalogRevision;
    if (gap) {
      return {
        fromRevision,
        revision: state.catalogRevision,
        journalLowerBound,
        reset: true,
        upserts: Object.values(state.catalog).map(cloneJSON),
        tombstones: [],
      };
    }
    const events = state.events.filter((event) => (
      event.scope === "catalog" && event.revision > fromRevision
    ));
    return {
      fromRevision,
      revision: state.catalogRevision,
      journalLowerBound,
      reset: false,
      upserts: events.filter((event) => event.op === "upsert").map((event) => cloneJSON(event.payload)),
      tombstones: events.filter((event) => event.op === "delete").map((event) => ({
        threadId: event.threadId,
        revision: event.revision,
      })),
    };
  }

  function threadSince(threadId, revision) {
    const normalizedThreadId = normalizeString(threadId);
    const fromRevision = readRevision(revision);
    const currentRevision = currentThreadRevision(normalizedThreadId);
    const journalLowerBound = lowerBound("thread", normalizedThreadId);
    const gap = fromRevision < journalLowerBound || fromRevision > currentRevision;
    return {
      threadId: normalizedThreadId,
      fromRevision,
      revision: currentRevision,
      journalLowerBound,
      resetRequired: gap,
      events: gap
        ? []
        : state.events
          .filter((event) => event.scope === "thread"
            && event.threadId === normalizedThreadId
            && event.revision > fromRevision)
          .map((event) => ({ revision: event.revision, ...cloneJSON(event.payload) })),
    };
  }

  function ack(params = {}) {
    const phoneDeviceId = normalizeString(params.phoneDeviceId) || "active-phone";
    const previous = state.acks[phoneDeviceId] || { threads: {} };
    const threads = { ...previous.threads };
    for (const [threadId, revision] of Object.entries(params.threadRevisions || {})) {
      threads[threadId] = Math.max(readRevision(revision), readRevision(threads[threadId]));
    }
    state.acks[phoneDeviceId] = {
      catalogRevision: Math.max(readRevision(params.catalogRevision), readRevision(previous.catalogRevision)),
      threads,
      updatedAt: now(),
    };
    schedulePersist();
    return { ok: true, acknowledgedAt: state.acks[phoneDeviceId].updatedAt };
  }

  function appendEvent(event) {
    const complete = { ...event, timestamp: now() };
    state.events.push(complete);
    if (complete.eventKey) {
      seenEventKeys.add(complete.eventKey);
    }
    prune();
    schedulePersist();
  }

  function prune() {
    const cutoff = now() - maxAgeMs;
    while (state.events.length > 0 && state.events[0].timestamp < cutoff) {
      removeFirstEvent();
    }
    while (state.events.length > maxEvents) {
      removeFirstEvent();
    }
  }

  function removeFirstEvent() {
    const removed = state.events.shift();
    if (removed?.eventKey) {
      seenEventKeys.delete(removed.eventKey);
    }
  }

  function lowerBound(scope, threadId = "") {
    const first = state.events.find((event) => (
      event.scope === scope && (scope !== "thread" || event.threadId === threadId)
    ));
    if (first) {
      return Math.max(0, first.revision - 1);
    }
    return scope === "catalog" ? state.catalogRevision : currentThreadRevision(threadId);
  }

  function currentThreadRevision(threadId) {
    return readRevision(state.threadRevisions[normalizeString(threadId)]);
  }

  function schedulePersist() {
    if (!persist || persistTimer) {
      return;
    }
    persistTimer = setTimeoutFn(() => {
      persistTimer = null;
      flush();
    }, 250);
    persistTimer.unref?.();
  }

  function flush() {
    if (!persist || !stateFilePath) {
      return;
    }
    if (persistTimer) {
      clearTimeoutFn(persistTimer);
      persistTimer = null;
    }
    fsImpl.mkdirSync(path.dirname(stateFilePath), { recursive: true });
    const tempPath = `${stateFilePath}.${process.pid}.tmp`;
    fsImpl.writeFileSync(tempPath, JSON.stringify(state), { mode: 0o600 });
    fsImpl.renameSync(tempPath, stateFilePath);
  }

  function stop() {
    flush();
  }

  return {
    ack,
    appendThreadEvent,
    catalogSince,
    currentThreadRevision,
    deleteCatalogThread,
    flush,
    hello,
    ingestCatalog,
    state,
    stop,
    threadSince,
    upsertCatalogThread,
  };
}

function emptyState() {
  return {
    version: SYNC_PROTOCOL_VERSION,
    catalogRevision: 0,
    threadRevisions: {},
    catalog: {},
    events: [],
    acks: {},
  };
}

function readState(stateFilePath, fsImpl) {
  if (!stateFilePath || !fsImpl.existsSync(stateFilePath)) {
    return null;
  }
  try {
    const state = JSON.parse(fsImpl.readFileSync(stateFilePath, "utf8"));
    if (state?.version !== SYNC_PROTOCOL_VERSION
      || !Array.isArray(state.events)
      || typeof state.catalog !== "object"
      || typeof state.threadRevisions !== "object") {
      return null;
    }
    return state;
  } catch {
    return null;
  }
}

function extractThreadRows(response) {
  const result = response?.result || response || {};
  for (const key of ["data", "threads", "items"]) {
    if (Array.isArray(result?.[key])) {
      return result[key];
    }
  }
  return [];
}

function extractThread(response) {
  const result = response?.result || response || null;
  return result?.thread || result;
}

function extractTurnRows(response) {
  if (!response || typeof response !== "object") {
    return [];
  }
  const rows = response.data || response.items || response.turns;
  return Array.isArray(rows) ? rows : [];
}

function readNextCursor(response) {
  if (!response || typeof response !== "object") {
    return null;
  }
  return response.nextCursor ?? response.next_cursor ?? response.cursor ?? null;
}

function extractTurns(thread) {
  return Array.isArray(thread?.turns) ? thread.turns : [];
}

function readThreadId(value) {
  return normalizeString(
    value?.threadId
      || value?.thread_id
      || value?.id
      || value?.thread?.id
      || value?.params?.threadId
      || value?.params?.thread_id
      || value?.params?.thread?.id
  );
}

function requireThreadId(params) {
  const threadId = readThreadId(params);
  if (!threadId) {
    throw syncError("thread_id_required", "同步请求缺少 threadId。 ");
  }
  return threadId;
}

function readStableEventKey(message) {
  const params = message?.params || {};
  const explicit = normalizeString(
    params.eventId || params.event_id || params.notificationId || params.notification_id
  );
  if (explicit) {
    return explicit;
  }
  const method = normalizeString(message?.method);
  if (/delta$/i.test(method)) {
    return "";
  }
  return sha256(stableJSON({ method, params }));
}

function catalogEventKey(op, threadId, payload, source) {
  return `catalog:${sha256(stableJSON({ op, threadId, payload, method: source?.method }))}`;
}

function stableJSON(value) {
  return JSON.stringify(sortValue(value));
}

function sortValue(value) {
  if (Array.isArray(value)) {
    return value.map(sortValue);
  }
  if (!value || typeof value !== "object") {
    return value;
  }
  return Object.fromEntries(Object.keys(value).sort().map((key) => [key, sortValue(value[key])]));
}

function cloneJSON(value) {
  return value == null ? value : JSON.parse(JSON.stringify(value));
}

function sha256(value) {
  return createHash("sha256").update(value).digest("hex");
}

function readRevision(value) {
  const revision = Number(value);
  return Number.isSafeInteger(revision) && revision >= 0 ? revision : 0;
}

function normalizeString(value) {
  return typeof value === "string" && value.trim() ? value.trim() : "";
}

function safeParseJSON(value) {
  try {
    return JSON.parse(value);
  } catch {
    return null;
  }
}

function syncError(errorCode, message) {
  return Object.assign(new Error(message), { errorCode, userMessage: message });
}

module.exports = {
  DEFAULT_HISTORY_PAGE_SIZE,
  DEFAULT_MAX_AGE_MS,
  DEFAULT_MAX_EVENTS,
  SYNC_PROTOCOL_VERSION,
  createRevisionJournal,
  createSyncCoordinator,
  extractThreadRows,
  readStableEventKey,
};
