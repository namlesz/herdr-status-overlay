import Foundation
import OverlayCore

/// 240 finished records with a 5000-byte argv (a [String], as Terminal defines it): about 1.2 MB on the wire, above the ordinary 1 MiB line limit.
func archivedHistoryFixture() -> [[String: Any]] {
    (0..<240).map { index -> [String: Any] in
        ["address": "old/\(index)", "state": "finished", "reported": true, "status": NSNull(), "argv": [String(repeating: "a", count: 5000)]]
    }
}

func checkCoreEvents() {
    func terminal(_ address: String, _ state: String = "working") -> [String: Any] {
        ["address": address, "state": "live", "reported": true, "status": ["state": state],
         "cwd": "/repo", "title": "task", "labels": ["agent": "true"]]
    }
    func event(_ seq: Any, _ type: String, _ address: String = "t1", _ data: Any = [String: Any]()) -> [String: Any] {
        ["jsonrpc": "2.0", "method": "event", "params": ["seq": seq, "type": type, "terminal": address, "data": data]]
    }
    func heartbeat(_ seq: Any) -> [String: Any] { ["jsonrpc": "2.0", "method": "heartbeat", "params": ["seq": seq]] }
    func missed(_ seq: Any, _ terminals: [[String: Any]]) -> [String: Any] {
        ["jsonrpc": "2.0", "method": "missed", "params": ["seq": seq, "terminals": terminals]]
    }
    func status(_ state: Any) -> [String: Any] { ["status": state, "records": [String: Any](), "reported": true] }
    func expect(_ condition: Bool, _ name: String, line: Int = #line) { check(condition, name, line: line) }
    do {
        var historical = terminal("t0", "done"); historical["state"] = "finished"
        var reducer = try CoreEventReducer(snapshot: ["seq": 1, "terminals": [terminal("t1"), terminal("host/t2", "idle"), historical]])
        expect(try reducer.currentRecords().map(\.key.paneID) == ["t1", "host/t2"], "event snapshot filters history, keeps local and remote")
        expect(try reducer.apply(event(2, "status", "t1", status(["state": "done"])))?.first?.status == .done, "status replaces root status")
        expect(try reducer.apply(event(3, "status", "t1", status(["state": "idle"])))?.first?.status == .idle, "sequential done and idle are both reduced")
        _ = try reducer.apply(event(4, "turn", "t1", ["turn": 999, "state": "done"]))
        expect(try reducer.currentRecords().first?.status == .idle, "turn's state never replaces root status")
        expect(try reducer.apply(event(5, "title", "t1", ["title": "new"]))?.first?.activity == "new", "title changes activity")
        for (seq, type, data) in [(6, "labels", ["labels": ["agent": "true"]] as [String: Any]),
                                  (7, "size", ["cols": 80, "rows": 24]), (8, "keep", ["keep": true])] {
            _ = try reducer.apply(event(seq, type, "t1", data))
        }
        _ = try reducer.apply(event(9, "foreground", "t1", NSNull()))
        expect(try reducer.currentRecords().first?.status == .idle, "non-display metadata leaves status unchanged")
        _ = try reducer.apply(event(10, "lost", "t1", ["reason": "signaled", "exit_code": NSNull(), "signal": 9, "finished_ms": NSNull()]))
        expect(try reducer.currentRecords().contains { $0.key.paneID == "t1" }, "kept lost terminal stays live")
        _ = try reducer.apply(event(11, "finished", "t1", ["reason": "exited", "exit_code": 0, "signal": NSNull(), "finished_ms": 123]))
        expect(try !reducer.currentRecords().contains { $0.key.paneID == "t1" }, "finished terminal is hidden")
        _ = try reducer.apply(event(12, "created", "t3", terminal("t3")))
        _ = try reducer.apply(event(13, "restarted", "t3", terminal("t3", "blocked")))
        expect(try reducer.currentRecords().first { $0.key.paneID == "t3" }?.status == .blocked, "created and restarted upsert complete records")
        _ = try reducer.apply(event(14, "removed", "t3"))
        expect(try !reducer.currentRecords().contains { $0.key.paneID == "t3" }, "removed drops record")
        _ = try reducer.apply(["jsonrpc": "2.0", "method": "event", "params": ["seq": 15, "type": "doc", "data": ["name": "app", "version": 1]]])
        _ = try reducer.apply(heartbeat(15))
        check(reducer.sequence == 15, "actual heartbeat method accepts unchanged sequence")
        _ = try reducer.apply(missed(15, [terminal("host/t4")]))
        expect(try reducer.currentRecords().map(\.key.paneID) == ["host/t4"], "actual missed method replaces snapshot at equal sequence")
        _ = try reducer.apply(event(15, "removed", "host/t4"))
        _ = try reducer.apply(missed(14, []))
        expect(try reducer.currentRecords().count == 1, "events at or below snapshot and older missed are ignored")
        _ = try reducer.apply(event(16, "status", "host/t4", status(NSNull())))
        expect(try reducer.currentRecords().isEmpty, "cleared root status is omitted")
    } catch { check(false, "valid wire notifications reduce: \(error)") }

    for bad in [true as Any, -1, 1.5, "1"] {
        do { _ = try CoreEventReducer(snapshot: ["seq": bad, "terminals": []]); check(false, "invalid sequence rejected") }
        catch { check(true, "invalid sequence rejected") }
    }
    do {
        var reducer = try CoreEventReducer(snapshot: ["seq": NSNumber(value: UInt64.max), "terminals": [terminal("t1")]])
        check(reducer.sequence == UInt64.max, "full uint64 sequence is preserved without a Double conversion")
        _ = try reducer.apply(event(1, "removed"))
        expect(try reducer.currentRecords().count == 1, "large unsigned sequence cannot turn negative and accept stale events")
        _ = try reducer.apply(missed(NSNumber(value: UInt64.max), []))
        expect(try reducer.currentRecords().isEmpty, "uint64 max missed snapshot still resynchronizes")
    } catch { check(false, "unsigned sequence boundary: \(error)") }
    do {
        _ = try CoreEventReducer(snapshot: ["seq": 0, "terminals": [terminal("t1"), terminal("t1")]])
        check(false, "duplicate addresses rejected")
    } catch { check(true, "duplicate addresses rejected") }

    do {
        let records = try CoreEventReducer(snapshot: ["seq": 1, "terminals": [terminal("t1"), terminal("host/t2"), terminal("local/t3"), terminal("unknown/t4")]]).currentRecords()
        var remote = CoreRemoteState()
        check(remote.visible(records).map(\.key.paneID) == ["t1"], "failed initial monitor never blocks local or exposes unverified remote")
        let connected = MachineAvailability(known: ["host", "local"], connected: ["host", "local"])
        remote.update(connected)
        check(remote.visible(records).map(\.key.paneID) == ["t1", "host/t2", "local/t3"], "connected baseline includes a machine named local, excludes unknown prefixes")
        remote.update(nil)
        check(remote.visible(records).map(\.key.paneID) == ["t1"], "monitor failure hides all remote")
        remote.update(connected)
        check(remote.visible(records).count == 3, "monitor recovery preserves healthy stream sync")
        remote.update(MachineAvailability(known: ["host", "local"], connected: ["local"]))
        remote.update(connected)
        check(remote.visible(records).map(\.key.paneID) == ["t1", "local/t3"], "connected alone never revives known stale mirrors or affects other machines")
        remote.didSynchronize(records)
        check(remote.visible(records).count == 3, "missed authorizes synchronized connected mirrors")
        remote.update(MachineAvailability(known: ["host", "local"], connected: ["local"]))
        remote.didSynchronize(records)
        check(remote.visible(records).count == 2, "sync before connectivity poll still withholds disconnected machine")
        remote.update(connected)
        check(remote.visible(records).count == 3, "completed sync is retained when connected poll arrives later")
        remote.update(MachineAvailability(known: ["local"], connected: ["local"]))
        check(remote.visible(records).map(\.key.paneID) == ["t1", "local/t3"], "forgetting a machine never makes its cached addresses local")
    } catch { check(false, "remote readiness: \(error)") }

    do {
        // Empty sync before discovery: the next poll shows the new machine connected, and its agent must not wait for a missed that never comes.
        let records = try CoreEventReducer(snapshot: ["seq": 1, "terminals": [terminal("t1"), terminal("new/t7")]]).currentRecords()
        var remote = CoreRemoteState()
        remote.update(MachineAvailability(known: [], connected: []))
        remote.didSynchronize([])
        remote.update(MachineAvailability(known: ["new"], connected: ["new"]))
        expect(remote.visible(records).map(\.key.paneID) == ["t1", "new/t7"], "machine discovered connected after an empty sync shows its agent")
    } catch { check(false, "newly discovered machine: \(error)") }

    do {
        // Over 1 MiB of finished history: only live records reach the parser; stubs still accept later metadata and removal.
        let history = archivedHistoryFixture()
        let snapshot: [String: Any] = ["seq": 1, "terminals": history + [terminal("t1")]]
        let wireBytes = try JSONSerialization.data(withJSONObject: snapshot).count
        check(wireBytes > AgentListParser.maxBytes, "history fixture exceeds the ordinary 1 MiB line limit")
        var reducer = try CoreEventReducer(snapshot: snapshot)
        expect(try reducer.currentRecords().map(\.key.paneID) == ["t1"], "over 1 MiB of finished history still yields the live agent")
        _ = try reducer.apply(event(2, "title", "old/0", ["title": "late"]))
        _ = try reducer.apply(event(3, "restarted", "old/1", history[1]))
        _ = try reducer.apply(event(4, "lost", "old/2", ["reason": "signaled", "exit_code": NSNull(), "signal": 9, "finished_ms": NSNull()]))
        _ = try reducer.apply(event(5, "removed", "old/0"))
        expect(try reducer.currentRecords().map(\.key.paneID) == ["t1"], "stub metadata, restart and late lost leave history hidden")
    } catch { check(false, "finished history retention: \(error)") }

    // A malformed lifecycle state is a parser error, not an empty healthy snapshot: only explicit "finished" is skipped.
    for state in [42 as Any, "bogus", NSNull()] {
        var malformed = terminal("t2"); malformed["state"] = state
        do {
            _ = try CoreEventReducer(snapshot: ["seq": 1, "terminals": [terminal("t1"), malformed]]).currentRecords()
            check(false, "malformed terminal state is rejected in snapshots")
        } catch ParseError.invalidField("state") {
            check(true, "malformed terminal state is rejected in snapshots")
        } catch { check(false, "malformed terminal state raises the parser error: \(error)") }
    }

    do {
        var now: UInt64 = 0
        let model = OverlayModel(sources: [.local(executable: "/fake")], clock: { now })
        let records = try CoreEventReducer(snapshot: ["seq": 1, "terminals": [terminal("t1")]]).currentRecords()
        let generation = model.begin("local")
        model.streamUpdate("local", generation: generation, agents: records, baseline: true)
        now = seconds(30)
        model.streamUpdate("local", generation: generation, agents: records, refresh: false)
        now = seconds(46)
        check(model.snapshot()[0].stale, "machine-only updates cannot keep a silent stream fresh")
        model.streamHeartbeat("local", generation: generation)
        check(model.snapshot()[0].stale, "late heartbeat cannot resurrect an expired source")
        model.wake()
        model.streamUpdate("local", generation: generation, agents: records, baseline: true)
        model.streamHeartbeat("local", generation: generation)
        check(model.snapshot()[0].problem == .afterWake, "old stream generation cannot clear wake invalidation")
        let current = model.begin("local")
        now = seconds(47)
        model.streamUpdate("local", generation: current, agents: records, baseline: true)
        model.streamFailure("local", generation: generation, failure: .malformed)
        check(!model.snapshot()[0].stale, "old generation failure cannot invalidate recovered stream")
        var reducer = try CoreEventReducer(snapshot: ["seq": 1, "terminals": [terminal("t1")]])
        now = seconds(48)
        model.streamUpdate("local", generation: current, agents: try reducer.apply(event(2, "status", "t1", status(["state": "done"])))!)
        now = seconds(49)
        model.streamUpdate("local", generation: current, agents: try reducer.apply(event(3, "status", "t1", status(["state": "idle"])))!)
        check(model.snapshot()[0].rows[0].status == .done && model.snapshot()[0].rows[0].completionEventAt == seconds(48), "done then idle preserves TTL and celebration before UI coalescing")
        for time in [60.0, 75, 90, 105, 120] { now = seconds(time); model.streamHeartbeat("local", generation: current) }
        check(!model.snapshot()[0].stale && model.snapshot()[0].rows.count == 1, "heartbeats preserve idle cache beyond retention")
        check(model.snapshot()[0].rows[0].status == .idle, "heartbeats do not renew done TTL")
        model.streamUpdate("local", generation: current, agents: try CoreEventReducer(snapshot: ["seq": 4, "terminals": [terminal("t1", "done")]]).currentRecords(), baseline: true)
        check(model.snapshot()[0].rows[0].completionEventAt == nil, "missed baseline does not celebrate recovery")
    } catch { check(false, "stream model lifecycle: \(error)") }
}
