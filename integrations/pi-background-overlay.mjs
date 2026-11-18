import { randomUUID } from "node:crypto";

const BG = "pi-background-tasks:host:";
const SUB = "subagents:rpc:v1:";
const LABEL = "overlay.pi-jobs";
const COALESCE_MS = 250;
const TIMEOUT_MS = 1_000;
const MAX_COUNT = 65_535; // Overlay wire format uses UInt16.
const BG_TERMINAL = new Set(["completed", "failed", "killed"]);
const SUB_TERMINAL = new Set(["complete", "failed", "partial", "stopped", "rejected"]);
const clamp = (n) => Math.min(MAX_COUNT, n);
const validId = (id) => typeof id === "string" && id.length > 0 && id.length <= 200;
const later = (fn, ms = COALESCE_MS) => setTimeout(fn, ms).unref();

export default function piBackgroundOverlay(pi) {
  // Only address the local HC terminal explicitly assigned to this Pi, never a pane name.
  const terminal = process.env.HC_TERMINAL_ID;
  if (!/^t[0-9a-z]{1,31}$/.test(terminal ?? "") || process.env.PI_SUBAGENT_CHILD === "1") return;

  const clientId = randomUUID();
  let session;
  let subReady;
  const listeners = [];
  const on = (channel, handler) => listeners.push(pi.events.on(channel, handler));

  async function writeLabel(value) {
    try {
      const result = await pi.exec("hc", ["label", terminal, `${LABEL}=${value}`], {
        timeout: TIMEOUT_MS, maxBuffer: 8192,
      });
      return result.code === 0 && !result.killed && !result.truncated;
    } catch {
      // Optional integration; never log command output or disrupt Pi.
      return false;
    }
  }

  function labelValue(s) {
    const running = clamp(s.bgRunning + s.subRunning.size);
    const finished = clamp(s.bgFinished.size + s.subFinished.size);
    return running || finished || s.subPartial ? `v1:${running}${s.subPartial ? "+" : ""}:${finished}` : "";
  }

  function publish(s, retriedValue) {
    if (s !== session || s.publishTimer || s.writing) return;
    s.publishTimer = later(() => {
      s.publishTimer = undefined;
      const value = labelValue(s);
      if (s.lastWritten === value) return;
      s.writing = writeLabel(value).then((ok) => {
        s.lastWritten = ok ? value : undefined;
        s.writing = undefined;
        if (labelValue(s) !== value) publish(s);
        else if (!ok && retriedValue !== value) publish(s, value);
      });
    });
  }

  function bgRequest(operation, request_id, payload) {
    pi.events.emit(`${BG}request:v1`, {
      schema_version: "pi-background-tasks.host-request.v1", request_id, operation, payload,
    });
  }
  function subscribeBg(s) {
    if (s.bgLease) return;
    s.bgRequest = randomUUID();
    bgRequest("subscribe", s.bgRequest, { clientId });
  }
  function bgCounts(s, frame) {
    const count = frame.counts?.running;
    if (!Number.isSafeInteger(frame.revision) || frame.revision < s.bgRevision ||
        !Number.isSafeInteger(count) || count < 0) return;
    s.bgRevision = frame.revision;
    if (count !== s.bgRunning) {
      s.bgRunning = count;
      publish(s);
    }
  }
  on(`${BG}response:v1`, (frame) => {
    const s = session;
    if (!s || frame?.schema_version !== "pi-background-tasks.host-response.v1" ||
        frame.operation !== "subscribe" || frame.request_id !== s.bgRequest || !frame.ok) return;
    const result = frame.result;
    if (result?.sessionId !== s.id || !validId(result.activationId) || !validId(result.leaseId)) return;
    s.bgLease = { leaseId: result.leaseId, activationId: result.activationId, sequence: 1 };
    bgCounts(s, result);
  });
  on(`${BG}changed:v1`, (frame) => {
    const s = session;
    if (!s || frame?.schema_version !== "pi-background-tasks.host-changed.v1" || frame.sessionId !== s.id) return;
    if (frame.kind === "ready") subscribeBg(s);
    if (frame.activationId !== s.bgLease?.activationId) return;
    if (frame.kind === "changed") bgCounts(s, frame);
    if (frame.kind === "closed") {
      s.bgLease = undefined;
      s.bgClosed = true;
      s.bgRunning = 0;
      publish(s);
    }
  });
  on("pi-background-tasks:terminal:v1", (frame) => {
    const s = session;
    if (!s || s.bgClosed || frame?.schema_version !== "pi-background-tasks.extension-terminal.v1") return;
    const task = frame.task;
    // Reload may deliver a survivor's pending terminal event. Use actual end time, not arrival time.
    if (!validId(task?.id) || !BG_TERMINAL.has(task.status) ||
        !Number.isSafeInteger(task.endTime) || task.endTime <= s.startedAt ||
        s.bgFinished.size >= MAX_COUNT || s.bgFinished.has(task.id)) return;
    s.bgFinished.add(task.id);
    publish(s);
  });

  function finishSub(s, id) {
    if (!s.subEligible.delete(id) || s.subFinished.size >= MAX_COUNT) return;
    s.subFinished.add(id);
    s.subRunning.delete(id);
    publish(s);
  }
  function trackSub(s, id) {
    if (validId(id) && s.subEligible.size < MAX_COUNT && !s.subFinished.has(id)) s.subEligible.add(id);
  }
  function refreshSub(s) {
    if (s !== session || subReady !== s.id) return;
    s.subDirty = true;
    if (s.subTimer || s.subCancel) return;
    s.subTimer = later(() => {
      s.subTimer = undefined;
      s.subDirty = false;
      const requestId = randomUUID();
      const done = () => {
        off();
        clearTimeout(deadline);
        s.subCancel = undefined;
      };
      const off = pi.events.on(`${SUB}reply:${requestId}`, (frame) => {
        if (frame?.version !== 1 || frame.requestId !== requestId || frame.method !== "status") return;
        done();
        if (s !== session) return;
        const snapshot = frame.success ? frame.data?.asyncSnapshot : undefined;
        if (snapshot?.kind === "pi-subagents.async-status-snapshot" && snapshot.version === 1 &&
            Array.isArray(snapshot.runs)) {
          const running = new Set();
          for (const row of snapshot.runs) {
            if (!validId(row?.id)) continue;
            if (row.state === "running" || row.state === "queued") trackSub(s, row.id);
            if (row.state === "running" && !s.subFinished.has(row.id)) running.add(row.id);
            if (SUB_TERMINAL.has(row.state)) finishSub(s, row.id);
          }
          // shortcut: the DTO caps async roots; use a source aggregate if one becomes available.
          // Fleet totalActive also includes foreground children and cannot substitute here.
          const partial = snapshot.omitted?.runs > 0;
          const changed = s.subRunning.size !== running.size || s.subPartial !== partial;
          s.subRunning = running;
          s.subPartial = partial;
          if (changed) publish(s);
        }
        if (s.subDirty) refreshSub(s);
      });
      const deadline = later(() => {
        done();
        if (s.subDirty) refreshSub(s);
      }, TIMEOUT_MS);
      s.subCancel = done;
      pi.events.emit(`${SUB}request`, { version: 1, requestId, method: "status" });
    });
  }
  on(`${SUB}ready`, (frame) => {
    if (frame?.version !== 1 || !validId(frame.session?.sessionId)) return;
    if (session && frame.session.sessionId !== session.id) return;
    subReady = frame.session.sessionId;
    if (session) refreshSub(session);
  });
  function subEventForSession(event, s) {
    // Lifecycle events may use the Pi session file as their owner; RPC ready uses its UUID.
    const owner = event?.sessionId;
    return typeof owner === "string" && (owner === s.id || owner === s.sessionManager.getSessionFile());
  }
  on("subagent:async-started", (event) => {
    const s = session;
    if (!s || !subEventForSession(event, s)) return;
    if (!event.parentWorkflowRunId && !event.nestedRoute) trackSub(s, event.id);
    refreshSub(s);
  });
  on("subagent:async-complete", (event) => {
    const s = session;
    if (!s || !subEventForSession(event, s)) return;
    let state = event.state;
    if (state == null && typeof event.success === "boolean") state = event.success ? "complete" : "failed";
    if (SUB_TERMINAL.has(state) && Number.isSafeInteger(event.timestamp) && event.timestamp > s.startedAt) {
      finishSub(s, event.runId ?? event.id);
    }
    refreshSub(s);
  });
  for (const channel of ["subagent:jobs-changed", "subagent:child-status", "subagent:process-terminal"]) {
    on(channel, () => { if (session) refreshSub(session); });
  }

  pi.on("session_start", (_event, ctx) => {
    // Headless Pi descendants can inherit HC_TERMINAL_ID but do not own that terminal.
    if (ctx.mode !== "tui" || session) return;
    const id = ctx.sessionManager.getSessionId();
    if (!validId(id)) return;
    const s = session = {
      id, sessionManager: ctx.sessionManager, startedAt: Date.now(),
      bgRunning: 0, bgRevision: -1, bgFinished: new Set(),
      subRunning: new Set(), subPartial: false, subEligible: new Set(), subFinished: new Set(),
    };
    subscribeBg(s); // If not ready yet, its ready frame retries the lease, independent of load order.
    refreshSub(s);
    publish(s); // Also removes a stale label left by an earlier unclean exit.
  });

  pi.on("session_shutdown", async () => {
    const s = session;
    session = undefined;
    for (const off of listeners.splice(0)) off();
    if (!s) return;
    clearTimeout(s.publishTimer);
    clearTimeout(s.subTimer);
    s.subCancel?.();
    if (s.bgLease) bgRequest("unsubscribe", randomUUID(), s.bgLease);
    // Shutdown is awaited by Pi before replacing the runtime. Never race a late set with the clear.
    await s.writing;
    if (s.lastWritten !== "") await writeLabel("");
  });
}
