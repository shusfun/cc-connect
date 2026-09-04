const test = require("node:test");
const assert = require("node:assert/strict");
const {
  createRevisionJournal,
  createSyncCoordinator,
} = require("../src/sync-journal");

test("目录 revision 单调递增并返回删除 tombstone", () => {
  const journal = createRevisionJournal({ persist: false });
  journal.ingestCatalog([{ id: "thread-1", title: "A" }], { authoritative: true });
  journal.ingestCatalog([{ id: "thread-1", title: "B" }], { authoritative: true });
  journal.ingestCatalog([], { authoritative: true });

  const delta = journal.catalogSince(1);
  assert.equal(delta.revision, 3);
  assert.deepEqual(delta.upserts, [{ id: "thread-1", title: "B" }]);
  assert.deepEqual(delta.tombstones, [{ threadId: "thread-1", revision: 3 }]);
});

test("重复幂等事件不会推进任务 revision", () => {
  const journal = createRevisionJournal({ persist: false });
  assert.equal(journal.appendThreadEvent("thread-1", { method: "turn/started" }, { eventKey: "turn-1" }), 1);
  assert.equal(journal.appendThreadEvent("thread-1", { method: "turn/started" }, { eventKey: "turn-1" }), 1);
  assert.equal(journal.threadSince("thread-1", 0).events.length, 1);
});

test("裁剪仅让受影响的任务要求 reset", () => {
  let now = 1_000;
  const journal = createRevisionJournal({ persist: false, maxEvents: 2, now: () => now });
  journal.appendThreadEvent("thread-a", { method: "item/started", params: { itemId: "a1" } });
  now += 1;
  journal.appendThreadEvent("thread-b", { method: "item/started", params: { itemId: "b1" } });
  now += 1;
  journal.appendThreadEvent("thread-a", { method: "item/completed", params: { itemId: "a1" } });

  assert.equal(journal.threadSince("thread-a", 0).resetRequired, true);
  assert.equal(journal.threadSince("thread-b", 0).resetRequired, false);
});

test("sync coordinator 提供 hello、增量读取、单任务 reset 和 5 Turn 历史页", async () => {
  const calls = [];
  const coordinator = createSyncCoordinator({
    macDeviceId: "mac-1",
    persist: false,
    async sendCodexRequest(method, params) {
      calls.push({ method, params });
      if (method === "thread/list") {
        return { data: [{ id: "thread-1", title: "A" }] };
      }
      if (method === "thread/turns/list" && params.cursor == null) {
        return {
          data: Array.from({ length: 8 }, (_, i) => ({ id: `turn-${7 - i}` })),
          nextCursor: "older",
        };
      }
      return { data: [{ id: "turn-old" }], nextCursor: "next" };
    },
  });

  const request = (method, params = {}) => new Promise((resolve) => {
    coordinator.handleRequest(JSON.stringify({ id: method, method, params }), (raw) => resolve(JSON.parse(raw).result));
  });

  const hello = await request("sync/hello");
  assert.equal(hello.macDeviceId, "mac-1");
  assert.equal(hello.capabilities.historyCursorPageSize, 5);
  const catalog = await request("sync/catalog", { catalogRevision: 0 });
  assert.deepEqual(catalog.upserts, [{ id: "thread-1", title: "A" }]);
  const reset = await request("sync/thread/reset", { threadId: "thread-1" });
  assert.equal(reset.turns.length, 5);
  assert.equal(reset.turns[0].id, "turn-3");
  assert.equal(reset.beforeCursor, "older");
  const history = await request("sync/thread/read", { threadId: "thread-1", beforeCursor: "older" });
  assert.equal(history.pageSize, 5);
  assert.deepEqual(calls.at(-1), {
    method: "thread/turns/list",
    params: { threadId: "thread-1", cursor: "older", limit: 5 },
  });
});

test("sync coordinator 不拦截普通 Bridge 请求", () => {
  const coordinator = createSyncCoordinator({
    macDeviceId: "mac-1",
    sendCodexRequest: async () => ({}),
    persist: false,
  });

  assert.equal(
    coordinator.handleRequest(
      JSON.stringify({ id: "resume-1", method: "thread/resume", params: { threadId: "thread-1" } }),
      () => {}
    ),
    false
  );
  coordinator.stop();
});
