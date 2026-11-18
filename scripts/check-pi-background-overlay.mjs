import assert from "node:assert/strict";
import { EventEmitter } from "node:events";
import { test } from "node:test";
import adapter from "../integrations/pi-background-overlay.mjs";

const BG = "pi-background-tasks:host:";
const SUB = "subagents:rpc:v1:";
const LABEL = "overlay.pi-jobs=";
const OK = { code: 0 };

function mockPi(sessionId, exec = () => OK) {
  const bus = new EventEmitter();
  const hooks = new Map();
  const calls = [];
  const sessionFile = `/very/long/path/${"project-".repeat(24)}/${sessionId}.jsonl`;
  const ctx = { mode: "tui", sessionManager: { getSessionId: () => sessionId, getSessionFile: () => sessionFile } };
  const pi = {
    on: (event, fn) => hooks.set(event, fn),
    events: {
      on(channel, fn) {
        bus.on(channel, fn);
        return () => bus.off(channel, fn);
      },
      emit: (channel, frame) => bus.emit(channel, frame),
    },
    exec(command, args, options) {
      assert.equal(command, "hc");
      assert.deepEqual(args.slice(0, 2), ["label", "t7"]);
      assert.match(args[2], /^overlay\.pi-jobs=(?:v1:\d+\+?:\d+)?$/);
      assert.equal(args.length, 3);
      assert.equal(options.timeout, 1000);
      calls.push(args[2].slice(LABEL.length));
      return exec(calls.at(-1));
    },
  };
  return { pi, bus, calls, sessionFile, hooks, start: (mode = "tui") => hooks.get("session_start")?.({}, { ...ctx, mode }),
    shutdown: () => hooks.get("session_shutdown")?.({ reason: "resume" }, ctx) };
}

function mockSources(host, sessionId) {
  const { bus } = host;
  let running = 0;
  let revision = 0;
  let bgReady = false;
  let runs = [];
  let omitted = 0;
  let subRequests = 0;
  let offLease = false;
  const facts = () => ({ sessionId, activationId: "activation", revision,
    counts: { running, completed: 40, failed: 10, killed: 5 } });
  function bgChange(kind = "changed", overrides = {}) {
    bus.emit(`${BG}changed:v1`, { schema_version: "pi-background-tasks.host-changed.v1", kind, ...facts(), ...overrides });
  }
  bus.on(`${BG}request:v1`, ({ schema_version, request_id, operation, payload }) => {
    assert.equal(schema_version, "pi-background-tasks.host-request.v1");
    if (operation === "unsubscribe") {
      assert.deepEqual(payload, { leaseId: "lease", activationId: "activation", sequence: 1 });
      offLease = true;
      return;
    }
    assert.equal(operation, "subscribe");
    bus.emit(`${BG}response:v1`, {
      schema_version: "pi-background-tasks.host-response.v1", request_id, operation, ok: bgReady,
      ...(bgReady ? { result: { ...facts(), leaseId: "lease" } } : { error: { code: "UNAVAILABLE" } }),
    });
  });
  bus.on(`${SUB}request`, ({ version, method, requestId, params }) => {
    assert.equal(version, 1);
    assert.equal(method, "status");
    assert.equal(params, undefined);
    subRequests += 1;
    bus.emit(`${SUB}reply:${requestId}`, { version, requestId, method, success: true, data: {
      asyncSnapshot: { kind: "pi-subagents.async-status-snapshot", version: 1, runs, omitted: { runs: omitted } },
      fleet: { totalActive: 500 }, text: "private content",
    } });
  });
  return {
    bgCounts: (n) => { running = n; revision += 1; bgChange(); },
    bgReady: () => { bgReady = true; bgChange("ready"); },
    bgChange,
    bgTerminal: (id, status, endTime = Date.now() + 1) => bus.emit("pi-background-tasks:terminal:v1", {
      schema_version: "pi-background-tasks.extension-terminal.v1", task: { id, status, endTime, command: "private content" },
    }),
    subReady: () => bus.emit(`${SUB}ready`, { version: 1, session: { sessionId } }),
    subStatus: (...pairs) => { runs = pairs.map(([id, state]) => ({ id, state })); bus.emit("subagent:jobs-changed", { version: 1 }); },
    subOmitted: (n) => { omitted = n; bus.emit("subagent:jobs-changed", { version: 1 }); },
    subStart: (id, owner = host.sessionFile) => bus.emit("subagent:async-started", { id, sessionId: owner }),
    subFinish: (id, owner = host.sessionFile) => bus.emit("subagent:async-complete", {
      id, runId: id, state: "complete", sessionId: owner, timestamp: Date.now() + 1, results: ["private content"],
    }),
    get subRequests() { return subRequests; },
    get offLease() { return offLease; },
  };
}

test("Pi EventBus counts are isolated, deduplicated, and cleared without polling", async (t) => {
  const original = [process.env.HC_TERMINAL_ID, process.env.PI_SUBAGENT_CHILD];
  t.after(() => {
    for (const [i, key] of ["HC_TERMINAL_ID", "PI_SUBAGENT_CHILD"].entries()) {
      if (original[i] === undefined) delete process.env[key];
      else process.env[key] = original[i];
    }
  });
  t.mock.timers.enable({ apis: ["setTimeout", "Date"], now: 10_000 });
  const step = async (ms = 250) => { t.mock.timers.tick(ms); await Promise.resolve(); await Promise.resolve(); };

  delete process.env.PI_SUBAGENT_CHILD;
  delete process.env.HC_TERMINAL_ID;
  const outside = mockPi("outside");
  adapter(outside.pi);
  assert.equal(outside.hooks.size, 0);
  process.env.HC_TERMINAL_ID = "--not-a-terminal";
  adapter(outside.pi);
  assert.equal(outside.hooks.size, 0);
  process.env.HC_TERMINAL_ID = "t7";
  process.env.PI_SUBAGENT_CHILD = "1";
  adapter(outside.pi);
  assert.equal(outside.hooks.size, 0);
  delete process.env.PI_SUBAGENT_CHILD;
  const headless = mockPi("headless");
  adapter(headless.pi);
  headless.start("print");
  await step();
  await headless.shutdown();
  assert.deepEqual(headless.calls, []);

  const a = mockPi("session-a");
  const src = mockSources(a, "session-a");
  adapter(a.pi);
  src.subReady(); // Subagent handler loaded before adapter lifecycle callback.
  src.subStatus(["old", "complete"], ["a1", "running"], ["a1", "running"], ["a2", "queued"], ["paused", "paused"]);
  a.start();
  src.bgReady(); // BG handler becomes ready after adapter lifecycle callback.
  src.bgCounts(2);
  src.bgChange("changed", { sessionId: "another", counts: { running: 99 } });
  src.bgChange("changed", { revision: 0, counts: { running: 99 } });
  src.bgTerminal("historical", "completed", Date.now() - 1);
  src.subFinish("old"); // Replay, no observed active run.
  await step();
  assert.deepEqual(a.calls, ["v1:3:0"]);

  src.subStatus(["a1", "complete"], ["a2", "stopped"], ["old", "complete"], ["paused", "paused"]);
  src.bgCounts(0);
  src.bgTerminal("a1", "failed"); // Separate package namespace (same id as a subagent).
  src.bgTerminal("a1", "failed");
  src.subStart("instant");
  src.subFinish("instant");
  src.subFinish("instant");
  src.subStart("wrong-owner", "/wrong-session.jsonl");
  src.subFinish("wrong-owner", "/wrong-session.jsonl");
  src.subFinish("a1");
  for (let i = 0; i < 100; i++) a.bus.emit("subagent:jobs-changed", { version: 1 });
  await step();
  await step();
  assert.deepEqual(a.calls, ["v1:3:0", "v1:0:4"]);
  assert.equal(src.subRequests, 2);
  src.bgChange("changed", { revision: 5, counts: { running: 0, completed: 0 } });
  src.subStatus(); // Widget retention must not decrement or re-count any finishes.
  await step();
  await step(10_000);
  assert.deepEqual(a.calls, ["v1:3:0", "v1:0:4"]);
  assert.equal(src.subRequests, 3);
  await a.shutdown();
  assert.deepEqual(a.calls, ["v1:3:0", "v1:0:4", ""]);
  assert.equal(src.offLease, true);

  let settle;
  const b = mockPi("session-b", (value) => value ? new Promise((resolve) => { settle = resolve; }) : OK);
  const next = mockSources(b, "session-b");
  adapter(b.pi);
  next.bgReady();
  b.start();
  next.subReady();
  next.subStatus(["a1", "complete"], ["a2", "stopped"]);
  next.subFinish("a1", a.sessionFile);
  await step();
  assert.deepEqual(b.calls, [""]);
  next.bgCounts(1);
  await step();
  const cleanup = b.shutdown();
  next.bgTerminal("late", "completed");
  await step(10_000);
  assert.deepEqual(b.calls, ["", "v1:1:0"]);
  settle(OK);
  await cleanup;
  assert.deepEqual(b.calls, ["", "v1:1:0", ""]);

  const c = mockPi("session-c", () => c.calls.length === 1 ? { code: 1 } : OK);
  const last = mockSources(c, "session-c");
  adapter(c.pi);
  c.start();
  await step();
  assert.deepEqual(c.calls, [""]);
  await step();
  assert.deepEqual(c.calls, ["", ""]); // Retry clearing the stale label after a transient failure.
  last.subReady();
  last.subStatus(["one", "running"]);
  last.subOmitted(1);
  await step();
  await step();
  assert.equal(c.calls.at(-1), "v1:1+:0");
  last.subOmitted(0);
  await step();
  await step();
  assert.equal(c.calls.at(-1), "v1:1:0");
  await c.shutdown();
});
