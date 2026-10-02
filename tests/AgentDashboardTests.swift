import Foundation

enum TestFailure: Error {
    case failed(String)
}

func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() {
        throw TestFailure.failed(message)
    }
}

@main
struct AgentDashboardTests {
    static func main() throws {
        try expect(isCopilotActivityControlLabel("Cancel (⌘Escape)"), "Copilot cancel control should be active")
        try expect(isCopilotActivityControlLabel("Stop generating"), "Copilot stop control should be active")
        try expect(!isCopilotActivityControlLabel("Stop Cell Execution"), "notebook execution must not mark Copilot active")

        let controller = AgentStateController()
        try expect(controller.state == .idle, "initial state should be idle")

        controller.setUIAgentActive(true)
        try expect(controller.state == .working, "active chat control should show working")
        controller.setWaitingForInput(true)
        try expect(controller.state == .askingInput, "permission prompt should request input")
        controller.setWaitingForInput(false)
        try expect(controller.state == .working, "cleared prompt should resume working")
        controller.setUIAgentActive(false)
        try expect(controller.state == .completed, "finished UI activity should show completed")

        controller.agentStarted(id: "trace-1")
        try expect(controller.state == .working, "started agent should be working")
        controller.setWaitingForInput(true)
        try expect(controller.state == .askingInput, "permission prompt should request input")
        controller.setWaitingForInput(false)
        try expect(controller.state == .working, "cleared prompt should resume working")
        controller.agentCompleted(id: "trace-1")
        try expect(controller.state == .completed, "completed agent should show completed")

        var restoreCount = 0
        let scheduler = IdleClockRestoreScheduler(delay: 0.05) {
            restoreCount += 1
        }
        scheduler.stateChanged(.idle)
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        try expect(restoreCount == 1, "idle timer should restore the clock once")
        scheduler.stateChanged(.idle)
        scheduler.stateChanged(.working)
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        try expect(restoreCount == 1, "activity should cancel the pending clock restore")

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("divoom-agent-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let telemetryFile = directory.appendingPathComponent("copilot.jsonl")
        FileManager.default.createFile(atPath: telemetryFile.path, contents: nil)

        var events: [String] = []
        let tailer = CopilotTelemetryTailer(fileURL: telemetryFile) { event in
            switch event {
            case .started(let id): events.append("started:\(id)")
            case .completed(let id): events.append("completed:\(id)")
            }
        }
        tailer.start()
        let handle = try FileHandle(forWritingTo: telemetryFile)
        try handle.seekToEnd()
        handle.write(Data("{\"name\":\"copilot_chat.session.start\",\"traceId\":\"abc\"}\n".utf8))
        RunLoop.current.run(until: Date().addingTimeInterval(0.7))
        handle.write(Data("{\"name\":\"invoke_agent\",\"traceId\":\"abc\"}\n".utf8))
        try handle.close()
        RunLoop.current.run(until: Date().addingTimeInterval(0.7))
        tailer.stop()

        try expect(events == ["started:abc", "completed:abc"], "telemetry events were \(events)")
        print("AgentDashboardTests passed")
    }
}
