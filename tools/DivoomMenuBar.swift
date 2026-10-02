import AppKit
import Foundation
import IOBluetooth

final class DivoomMenuBar: NSObject, NSApplicationDelegate, NSMenuDelegate {
    let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    let menu = NSMenu()
    let repo: URL
    let toolRoot: URL
    let supportDir: URL
    var daemonProcess: Process?
    var statusItemViewTimer: Timer?
    var lastMessage = "Ready"
    var agentStateController: AgentStateController?
    var telemetryTailer: CopilotTelemetryTailer?
    var promptMonitor: VSCodePromptMonitor?
    var idleClockScheduler: IdleClockRestoreScheduler?
    var displayedAgentState: AgentDisplayState?
    let displayQueue = DispatchQueue(label: "divoom.agent-display")
    let logLock = NSLock()

    var address = "B1:21:81:B1:F0:84"
    let channel = "1"
    let daemonPort = "40583"
    var menuLog: URL { supportDir.appendingPathComponent("divoom-menubar.log") }
    var daemonLog: URL { supportDir.appendingPathComponent("divoom-menubar-daemon.log") }
    var daemonPidFile: URL { supportDir.appendingPathComponent("divoom-menubar-daemon.pid") }
    var capturesDir: URL { supportDir.appendingPathComponent("captures/mac-send") }
    var copilotTelemetryFile: URL { supportDir.appendingPathComponent("copilot-otel.jsonl") }
    var agentAssetsDir: URL { repo.appendingPathComponent("agent-assets", isDirectory: true) }

    override init() {
        let fm = FileManager.default
        let cwd = URL(fileURLWithPath: fm.currentDirectoryPath)
        let resources = Bundle.main.resourceURL
        let bundledTools = resources?.appendingPathComponent("tools")
        if let resources, let bundledTools, fm.fileExists(atPath: bundledTools.appendingPathComponent("divoom-daemon").path) {
            self.repo = resources
            self.toolRoot = bundledTools
        } else {
            self.repo = cwd
            self.toolRoot = cwd.appendingPathComponent("tools")
        }
        let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first ?? cwd
        self.supportDir = appSupport.appendingPathComponent("DivoomMiniToo", isDirectory: true)
        super.init()
        try? fm.createDirectory(at: supportDir, withIntermediateDirectories: true)
        try? fm.createDirectory(at: capturesDir, withIntermediateDirectories: true)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        if let discoveredAddress = discoverDivoomAddress() {
            address = discoveredAddress
        }
        appendLog("menubar started repo=\(repo.path)")
        appendLog("using Divoom address=\(address)")
        statusItem.button?.title = "◈ Divoom"
        menu.delegate = self
        rebuildMenu()
        statusItem.menu = menu
        statusItemViewTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.refreshTitle()
        }
        startAgentDashboard()
        refreshTitle()
        startDaemon(disconnectFirst: true)
    }

    func applicationWillTerminate(_ notification: Notification) {
        telemetryTailer?.stop()
        promptMonitor?.stop()
        idleClockScheduler?.cancel()
    }

    func refreshTitle() {
        let running = isDaemonRunning()
        let state = agentStateController?.state.title ?? AgentDisplayState.idle.title
        statusItem.button?.title = running ? "◆ Divoom · \(state)" : "◇ Divoom"
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        refreshTitle()
        rebuildMenu()
    }

    func rebuildMenu() {
        let daemonRunning = isDaemonRunning()
        let audioConnected = isAudioConnected()
        menu.removeAllItems()
        menu.addItem(disabled("Daemon: \(daemonRunning ? "Running" : "Stopped")"))
        menu.addItem(disabled("Device: \(address)"))
        menu.addItem(disabled("Audio profile: \(audioConnected ? "Connected" : "Disconnected")"))
        menu.addItem(disabled("Agent: \(agentStateController?.state.title ?? AgentDisplayState.idle.title)"))
        menu.addItem(disabled("Copilot telemetry: \(copilotTelemetryFile.path)"))
        menu.addItem(disabled("Input detection: \(promptMonitor?.isTrusted == true ? "Enabled" : "Needs Accessibility permission")"))
        menu.addItem(disabled("Last: \(shortStatus(lastMessage))"))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(item("Copy Copilot OTel Settings", #selector(copyCopilotSettings)))
        menu.addItem(item("Enable Accessibility Detection…", #selector(enableAccessibilityDetection), enabled: promptMonitor?.isTrusted != true))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(item("Preview: Working", #selector(previewWorking), enabled: daemonRunning))
        menu.addItem(item("Preview: Asking Input", #selector(previewAskingInput), enabled: daemonRunning))
        menu.addItem(item("Preview: Completed", #selector(previewCompleted), enabled: daemonRunning))
        menu.addItem(item("Preview: Idle", #selector(previewIdle), enabled: daemonRunning))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(item("Send Image/GIF/Video…", #selector(sendImage), enabled: daemonRunning))
        menu.addItem(item("Activate Custom Face 1", #selector(activateCustomFace1), enabled: daemonRunning))
        menu.addItem(item("Activate Custom Face 2", #selector(activateCustomFace2), enabled: daemonRunning))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(item("Start Daemon (only if audio disconnected)", #selector(startDaemonMenu), enabled: !daemonRunning && !audioConnected))
        menu.addItem(item("Disconnect Audio + Start Daemon", #selector(disconnectAndStartMenu), enabled: !daemonRunning))
        menu.addItem(item("Stop Daemon", #selector(stopDaemonMenu), enabled: daemonRunning))
        menu.addItem(item("Restart Daemon", #selector(restartDaemonMenu), enabled: true))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(item("Disconnect Divoom Audio", #selector(disconnectAudioMenu), enabled: audioConnected))
        menu.addItem(item("Reconnect Divoom Audio", #selector(reconnectAudioMenu), enabled: !audioConnected))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(item("Open Captures Folder", #selector(openCaptures)))
        menu.addItem(item("Open Protocol Notes", #selector(openProtocol)))
        menu.addItem(item("Open Menu Log", #selector(openMenuLog)))
        menu.addItem(item("Open Daemon Log", #selector(openDaemonLog)))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(item("Quit", #selector(quit)))
    }

    func item(_ title: String, _ action: Selector, enabled: Bool = true) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: action, keyEquivalent: "")
        i.target = self
        i.isEnabled = enabled
        return i
    }

    func disabled(_ title: String) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        i.isEnabled = false
        return i
    }

    func shortStatus(_ message: String, limit: Int = 72) -> String {
        let singleLine = message.replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\r", with: " ")
        if singleLine.count <= limit { return singleLine }
        return String(singleLine.prefix(limit - 1)) + "…"
    }

    func executablePath(_ name: String) -> String? {
        let candidates = [
            "/opt/homebrew/bin/\(name)",
            "/usr/local/bin/\(name)",
            "/usr/bin/\(name)",
            "/bin/\(name)"
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    func discoverDivoomAddress() -> String? {
        guard let devices = IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice] else { return nil }
        return devices.first {
            ($0.name ?? "").localizedCaseInsensitiveContains("Divoom MiniToo")
        }?.addressString?.uppercased()
    }

    func bluetoothDevice() -> IOBluetoothDevice? {
        IOBluetoothDevice(addressString: address)
    }

    func disconnectDevice() -> String? {
        guard let device = bluetoothDevice() else { return "Bluetooth device not found: \(address)" }
        let result = device.closeConnection()
        return result == kIOReturnSuccess ? nil : "Bluetooth disconnect failed: 0x\(String(result, radix: 16))"
    }

    func reconnectDevice() -> String? {
        guard let device = bluetoothDevice() else { return "Bluetooth device not found: \(address)" }
        let result = device.openConnection()
        return result == kIOReturnSuccess ? nil : "Bluetooth reconnect failed: 0x\(String(result, radix: 16))"
    }

    func run(_ executable: String, _ args: [String], wait: Bool = true) -> (Int32, String) {
        appendLog("run \(executable) \(args.joined(separator: " ")) wait=\(wait)")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: executable)
        p.arguments = args
        p.currentDirectoryURL = repo
        var env = ProcessInfo.processInfo.environment
        env["PYTHONDONTWRITEBYTECODE"] = "1"
        p.environment = env
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        do { try p.run() } catch { return (127, String(describing: error)) }
        if wait { p.waitUntilExit() }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let out = String(data: data, encoding: .utf8) ?? ""
        if wait { appendLog("run exit=\(p.terminationStatus) out=\(String(out.suffix(500)))") }
        return (p.terminationStatus, out)
    }

    func isDaemonRunning() -> Bool {
        if let pidText = try? String(contentsOf: daemonPidFile, encoding: .utf8),
           let pid = Int32(pidText.trimmingCharacters(in: .whitespacesAndNewlines)),
           pid > 0,
           kill(pid, 0) == 0 {
            return true
        }
        let daemonPath = toolRoot.appendingPathComponent("divoom-daemon").path
        let (code, _) = run("/usr/bin/pgrep", ["-f", daemonPath], wait: true)
        return code == 0
    }

    func isAudioConnected() -> Bool {
        bluetoothDevice()?.isConnected() == true
    }

    func setStatus(_ message: String) {
        appendLog("status \(message)")
        DispatchQueue.main.async {
            self.lastMessage = self.shortStatus(message, limit: 160)
            self.refreshTitle()
            self.rebuildMenu()
        }
    }

    func startAgentDashboard() {
        let controller = AgentStateController()
        controller.onStateChange = { [weak self] state in
            self?.agentStateChanged(state)
        }
        agentStateController = controller
        let clockScheduler = IdleClockRestoreScheduler { [weak self] in
            self?.restoreDefaultClockAfterIdle()
        }
        idleClockScheduler = clockScheduler
        clockScheduler.stateChanged(.idle)

        let telemetry = CopilotTelemetryTailer(fileURL: copilotTelemetryFile) { [weak self, weak controller] event in
            switch event {
            case .started(let id):
                self?.appendLog("copilot telemetry started id=\(id)")
                controller?.agentStarted(id: id)
            case .completed(let id):
                self?.appendLog("copilot telemetry completed id=\(id)")
                controller?.agentCompleted(id: id)
            }
        }
        telemetryTailer = telemetry
        telemetry.start()

        let accessibility = VSCodePromptMonitor(
            onChange: { [weak self, weak controller] waiting in
                self?.appendLog("copilot input prompt waiting=\(waiting)")
                controller?.setWaitingForInput(waiting)
            },
            onActivityChange: { [weak self, weak controller] active, label in
                self?.appendLog("copilot UI active=\(active) control=\(label ?? "-")")
                controller?.setUIAgentActive(active)
            },
            onTrustChange: { [weak self] trusted in
                self?.appendLog("accessibility trusted=\(trusted)")
            }
        )
        promptMonitor = accessibility
        if !accessibility.isTrusted {
            accessibility.requestAccess()
        }
        accessibility.start()
        appendLog("agent dashboard started telemetry=\(copilotTelemetryFile.path) accessibility=\(accessibility.isTrusted)")
    }

    func agentStateChanged(_ state: AgentDisplayState) {
        appendLog("agent state \(state.rawValue)")
        idleClockScheduler?.stateChanged(state)
        DispatchQueue.main.async {
            self.refreshTitle()
            self.rebuildMenu()
        }
        sendAgentState(state)
    }

    func sendAgentState(_ state: AgentDisplayState, force: Bool = false) {
        displayQueue.async {
            if !force, self.displayedAgentState == state { return }
            guard self.isDaemonRunning() else {
                self.setStatus("Agent \(state.title); daemon not running")
                return
            }
            let client = self.toolRoot.appendingPathComponent("divoom_status.py").path
            guard FileManager.default.isExecutableFile(atPath: "/usr/bin/python3"),
                  FileManager.default.fileExists(atPath: client),
                  FileManager.default.fileExists(atPath: self.agentAssetsDir.path) else {
                self.setStatus("Agent status assets or client missing")
                return
            }
            let (code, out) = self.run(
                "/usr/bin/python3",
                [client, state.rawValue, "--asset-dir", self.agentAssetsDir.path]
            )
            if code == 0 {
                self.displayedAgentState = state
                self.setStatus("Agent \(state.title) displayed")
            } else {
                self.setStatus("Agent display issue: \(String(out.suffix(500)))")
            }
        }
    }

    func startDaemon(disconnectFirst: Bool) {
        DispatchQueue.global(qos: .userInitiated).async {
            if disconnectFirst {
                if let error = self.disconnectDevice() {
                    self.appendLog(error)
                }
            }
            Thread.sleep(forTimeInterval: disconnectFirst ? 1.5 : 0.0)
            if self.isDaemonRunning() {
                self.setStatus("Daemon already running")
                return
            }
            let log = self.daemonLog
            let p = Process()
            p.executableURL = self.toolRoot.appendingPathComponent("divoom-daemon")
            p.arguments = [self.address, self.channel, self.daemonPort]
            p.currentDirectoryURL = self.repo
            let logHandle: FileHandle
            FileManager.default.createFile(atPath: log.path, contents: nil)
            do {
                logHandle = try FileHandle(forWritingTo: log)
                logHandle.truncateFile(atOffset: 0)
            } catch {
                self.notify("Failed to open daemon log: \(error)")
                return
            }
            p.standardOutput = logHandle
            p.standardError = logHandle
            do {
                try p.run()
                self.daemonProcess = p
                try? "\(p.processIdentifier)\n".write(to: self.daemonPidFile, atomically: true, encoding: .utf8)
                self.appendLog("daemon launched pid=\(p.processIdentifier) disconnectFirst=\(disconnectFirst)")
                Thread.sleep(forTimeInterval: 2.0)
                if self.isDaemonRunning() {
                    self.setStatus("Daemon started")
                    self.sendAgentState(self.agentStateController?.state ?? .idle, force: true)
                    self.idleClockScheduler?.stateChanged(self.agentStateController?.state ?? .idle)
                } else {
                    let logText = (try? String(contentsOf: log, encoding: .utf8)) ?? ""
                    try? FileManager.default.removeItem(at: self.daemonPidFile)
                    if logText.contains("0x-1ffffd44") {
                        self.setStatus("Start failed: audio/RFCOMM busy; use Disconnect Audio + Start")
                    } else {
                        self.setStatus("Daemon failed; see daemon log")
                    }
                }
            } catch {
                self.setStatus("Start failed: \(error)")
            }
        }
    }

    func stopDaemon() {
        DispatchQueue.global(qos: .userInitiated).async {
            self.daemonProcess?.terminate()
            self.daemonProcess = nil
            if let pidText = try? String(contentsOf: self.daemonPidFile, encoding: .utf8),
               let pid = Int32(pidText.trimmingCharacters(in: .whitespacesAndNewlines)),
               pid > 0,
               kill(pid, 0) == 0 {
                kill(pid, SIGTERM)
            }
            try? FileManager.default.removeItem(at: self.daemonPidFile)
            self.setStatus("Daemon stopped")
        }
    }

    @objc func startDaemonMenu() { startDaemon(disconnectFirst: false) }
    @objc func disconnectAndStartMenu() { startDaemon(disconnectFirst: true) }
    @objc func stopDaemonMenu() { stopDaemon() }
    @objc func restartDaemonMenu() {
        stopDaemon()
        DispatchQueue.global().asyncAfter(deadline: .now() + 1.0) { self.startDaemon(disconnectFirst: true) }
    }

    @objc func copyCopilotSettings() {
        let settings: [String: Any] = [
            "github.copilot.chat.otel.enabled": true,
            "github.copilot.chat.otel.exporterType": "file",
            "github.copilot.chat.otel.captureContent": false,
            "github.copilot.chat.otel.outfile": copilotTelemetryFile.path
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .sortedKeys]),
              let text = String(data: data, encoding: .utf8) else {
            setStatus("Could not create Copilot settings")
            return
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        setStatus("Copilot OTel settings copied")
    }

    @objc func enableAccessibilityDetection() {
        promptMonitor?.requestAccess()
        setStatus("Grant Accessibility access, then relaunch the app")
    }

    @objc func previewWorking() { previewAgentState(.working) }
    @objc func previewAskingInput() { previewAgentState(.askingInput) }
    @objc func previewCompleted() { previewAgentState(.completed) }
    @objc func previewIdle() { previewAgentState(.idle) }

    func previewAgentState(_ state: AgentDisplayState) {
        sendAgentState(state, force: true)
    }

    @objc func disconnectAudioMenu() {
        DispatchQueue.global().async {
            if let error = self.disconnectDevice() {
                self.setStatus(error)
            } else {
                self.setStatus("Audio disconnected")
            }
        }
    }

    @objc func reconnectAudioMenu() {
        DispatchQueue.global().async {
            if let error = self.reconnectDevice() {
                self.setStatus(error)
            } else {
                self.setStatus("Audio reconnect requested")
            }
        }
    }

    @objc func sendImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .jpeg, .gif, .image, .movie]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        DispatchQueue.global(qos: .userInitiated).async {
            if !self.isDaemonRunning() {
                self.setStatus("Daemon not running")
                return
            }
            let venvPy = self.repo.appendingPathComponent(".venv/bin/python").path
            let py = FileManager.default.isExecutableFile(atPath: venvPy) ? venvPy : (self.executablePath("python3") ?? "/usr/bin/python3")
            let client = self.toolRoot.appendingPathComponent("divoom_send.py").path
            let (code, out) = self.run(py, [client, url.path, "--out-dir", self.capturesDir.path])
            let detail = String(out.suffix(900))
            self.setStatus(code == 0 ? "Media sent" : "Send issue: \(detail)")
        }
    }

    func activateClock(_ shortcut: String, successMessage: String? = nil) {
        DispatchQueue.global(qos: .userInitiated).async {
            if !self.isDaemonRunning() {
                self.setStatus("Daemon not running")
                return
            }
            let venvPy = self.repo.appendingPathComponent(".venv/bin/python").path
            let py = FileManager.default.isExecutableFile(atPath: venvPy) ? venvPy : (self.executablePath("python3") ?? "/usr/bin/python3")
            let client = self.toolRoot.appendingPathComponent("divoom_clock.py").path
            let (code, out) = self.run(py, [client, shortcut, "--out-dir", self.capturesDir.path])
            let detail = String(out.suffix(700))
            self.setStatus(code == 0 ? (successMessage ?? "Activated custom face \(shortcut)") : "Clock issue: \(detail)")
        }
    }

    func restoreDefaultClockAfterIdle() {
        guard agentStateController?.state == .idle else { return }
        appendLog("Copilot idle for 5 minutes; restoring Win00 clock")
        activateClock("win00", successMessage: "Restored Win00 clock after 5 minutes idle")
    }

    @objc func activateCustomFace1() { activateClock("custom1") }
    @objc func activateCustomFace2() { activateClock("custom2") }

    @objc func openCaptures() {
        NSWorkspace.shared.open(capturesDir)
    }

    @objc func openProtocol() {
        let bundled = repo.appendingPathComponent("PROTOCOL.md")
        if FileManager.default.fileExists(atPath: bundled.path) {
            NSWorkspace.shared.open(bundled)
        } else {
            NSWorkspace.shared.open(URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("PROTOCOL.md"))
        }
    }

    @objc func openMenuLog() {
        NSWorkspace.shared.open(menuLog)
    }

    @objc func openDaemonLog() {
        NSWorkspace.shared.open(daemonLog)
    }

    @objc func quit() {
        NSApp.terminate(nil)
    }

    func notify(_ title: String, detail: String = "") { setStatus(detail.isEmpty ? title : "\(title): \(detail)") }

    func appendLog(_ line: String) {
        logLock.lock()
        defer { logLock.unlock() }
        let ts = ISO8601DateFormatter().string(from: Date())
        let text = "[\(ts)] \(line)\n"
        if !FileManager.default.fileExists(atPath: menuLog.path) {
            FileManager.default.createFile(atPath: menuLog.path, contents: nil)
        }
        if let h = try? FileHandle(forWritingTo: menuLog) {
            h.seekToEndOfFile()
            h.write(Data(text.utf8))
            try? h.close()
        }
    }
}

@main
struct DivoomMiniTooApp {
    static func main() {
        let app = NSApplication.shared
        let delegate = DivoomMenuBar()
        app.delegate = delegate
        app.run()
    }
}
