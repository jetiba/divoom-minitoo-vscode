import AppKit
import ApplicationServices
import Foundation

enum AgentDisplayState: String, CaseIterable {
    case idle
    case working
    case askingInput = "asking-input"
    case completed

    var title: String {
        switch self {
        case .idle: return "Idle"
        case .working: return "Working"
        case .askingInput: return "Asking Input"
        case .completed: return "Completed"
        }
    }
}

enum CopilotTelemetryEvent {
    case started(String)
    case completed(String)
}

func isCopilotActivityControlLabel(_ label: String) -> Bool {
    let normalized = label.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    let exactLabels = Set([
        "stop",
        "stop request",
        "stop generating",
        "cancel",
        "cancel request",
        "cancel generation"
    ])
    return exactLabels.contains(normalized) || normalized.hasPrefix("cancel (")
}

final class AgentStateController {
    private var activeRuns: [String: Date] = [:]
    private var isUIAgentActive = false
    private var isWaitingForInput = false
    private var completedUntil: Date?
    private var completionTimer: Timer?
    private(set) var state: AgentDisplayState = .idle
    var onStateChange: ((AgentDisplayState) -> Void)?

    func agentStarted(id: String) {
        activeRuns[id] = Date()
        completedUntil = nil
        recompute()
    }

    func agentCompleted(id: String) {
        let wasActive = hasActiveInteraction
        if activeRuns.removeValue(forKey: id) == nil,
           let oldest = activeRuns.min(by: { $0.value < $1.value })?.key {
            activeRuns.removeValue(forKey: oldest)
        }
        completeIfInteractionEnded(wasActive: wasActive)
        recompute()
    }

    func setWaitingForInput(_ waiting: Bool) {
        let wasActive = hasActiveInteraction
        guard isWaitingForInput != waiting else { return }
        isWaitingForInput = waiting
        if waiting {
            completedUntil = nil
        } else {
            completeIfInteractionEnded(wasActive: wasActive)
        }
        recompute()
    }

    func setUIAgentActive(_ active: Bool) {
        let wasActive = hasActiveInteraction
        guard isUIAgentActive != active else { return }
        isUIAgentActive = active
        if active {
            completedUntil = nil
        } else {
            completeIfInteractionEnded(wasActive: wasActive)
        }
        recompute()
    }

    private var hasActiveInteraction: Bool {
        !activeRuns.isEmpty || isUIAgentActive || isWaitingForInput
    }

    private func completeIfInteractionEnded(wasActive: Bool) {
        guard wasActive, !hasActiveInteraction else { return }
        completedUntil = Date().addingTimeInterval(8)
        completionTimer?.invalidate()
        completionTimer = Timer.scheduledTimer(withTimeInterval: 8, repeats: false) { [weak self] _ in
            self?.completedUntil = nil
            self?.recompute()
        }
    }

    private func recompute() {
        let newState: AgentDisplayState
        if isWaitingForInput {
            newState = .askingInput
        } else if !activeRuns.isEmpty || isUIAgentActive {
            newState = .working
        } else if let completedUntil, completedUntil > Date() {
            newState = .completed
        } else {
            newState = .idle
        }
        update(newState)
    }

    private func update(_ newState: AgentDisplayState) {
        guard state != newState else { return }
        state = newState
        onStateChange?(newState)
    }
}

final class IdleClockRestoreScheduler {
    private let delay: TimeInterval
    private let restore: () -> Void
    private var timer: Timer?

    init(delay: TimeInterval = 300, restore: @escaping () -> Void) {
        self.delay = delay
        self.restore = restore
    }

    func stateChanged(_ state: AgentDisplayState) {
        timer?.invalidate()
        timer = nil
        guard state == .idle else { return }
        timer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            self?.timer = nil
            self?.restore()
        }
    }

    func cancel() {
        timer?.invalidate()
        timer = nil
    }
}

final class CopilotTelemetryTailer {
    private let fileURL: URL
    private let onEvent: (CopilotTelemetryEvent) -> Void
    private var offset: UInt64 = 0
    private var pending = Data()
    private var timer: DispatchSourceTimer?
    private let queue = DispatchQueue(label: "divoom.copilot-telemetry")

    init(fileURL: URL, onEvent: @escaping (CopilotTelemetryEvent) -> Void) {
        self.fileURL = fileURL
        self.onEvent = onEvent
    }

    func start() {
        let manager = FileManager.default
        if !manager.fileExists(atPath: fileURL.path) {
            manager.createFile(atPath: fileURL.path, contents: nil)
        }
        offset = (try? manager.attributesOfItem(atPath: fileURL.path)[.size] as? NSNumber)?.uint64Value ?? 0
        let source = DispatchSource.makeTimerSource(queue: queue)
        source.schedule(deadline: .now() + 0.5, repeating: 0.5)
        source.setEventHandler { [weak self] in
            self?.readNewLines()
        }
        timer = source
        source.resume()
    }

    func stop() {
        timer?.cancel()
        timer = nil
    }

    private func readNewLines() {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
              let size = (attributes[.size] as? NSNumber)?.uint64Value else {
            return
        }
        if size < offset {
            offset = 0
            pending.removeAll()
        }
        guard size > offset, let handle = try? FileHandle(forReadingFrom: fileURL) else { return }
        defer { try? handle.close() }
        do {
            try handle.seek(toOffset: offset)
            guard let data = try handle.readToEnd(), !data.isEmpty else { return }
            offset += UInt64(data.count)
            pending.append(data)
            consumeLines()
        } catch {
            return
        }
    }

    private func consumeLines() {
        while let newline = pending.firstRange(of: Data([0x0a])) {
            let line = pending[..<newline.lowerBound]
            pending.removeSubrange(..<newline.upperBound)
            parse(Data(line))
        }
    }

    private func parse(_ data: Data) {
        guard !data.isEmpty,
              let object = try? JSONSerialization.jsonObject(with: data) else {
            return
        }
        let id = identifier(in: object) ?? UUID().uuidString
        if contains("copilot_chat.session.start", in: object) {
            DispatchQueue.main.async { self.onEvent(.started(id)) }
        }
        if contains("invoke_agent", in: object) {
            DispatchQueue.main.async { self.onEvent(.completed(id)) }
        }
    }

    private func contains(_ expected: String, in value: Any) -> Bool {
        if let string = value as? String {
            return string == expected
        }
        if let dictionary = value as? [String: Any] {
            return dictionary.values.contains { contains(expected, in: $0) }
        }
        if let array = value as? [Any] {
            return array.contains { contains(expected, in: $0) }
        }
        return false
    }

    private func identifier(in value: Any) -> String? {
        if let dictionary = value as? [String: Any] {
            let preferredKeys = ["traceId", "trace_id", "session.id", "sessionId", "gen_ai.conversation.id", "request_id"]
            for key in preferredKeys {
                if let result = dictionary[key] as? String, !result.isEmpty {
                    return result
                }
            }
            for nested in dictionary.values {
                if let result = identifier(in: nested) {
                    return result
                }
            }
        } else if let array = value as? [Any] {
            for nested in array {
                if let result = identifier(in: nested) {
                    return result
                }
            }
        }
        return nil
    }
}

final class VSCodePromptMonitor {
    private let onChange: (Bool) -> Void
    private let onActivityChange: (Bool, String?) -> Void
    private let onTrustChange: (Bool) -> Void
    private var timer: Timer?
    private var previousValue = false
    private var previousActivity = false
    private var previousTrust: Bool?

    private let appBundleIdentifiers = Set([
        "com.microsoft.VSCode",
        "com.microsoft.VSCodeInsiders",
        "com.microsoft.VSCodeExploration"
    ])
    private let confirmationLabels = Set([
        "allow",
        "allow once",
        "always allow",
        "approve",
        "submit"
    ])
    init(
        onChange: @escaping (Bool) -> Void,
        onActivityChange: @escaping (Bool, String?) -> Void = { _, _ in },
        onTrustChange: @escaping (Bool) -> Void = { _ in }
    ) {
        self.onChange = onChange
        self.onActivityChange = onActivityChange
        self.onTrustChange = onTrustChange
    }

    var isTrusted: Bool { AXIsProcessTrusted() }

    func requestAccess() {
        let promptKey = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        let options = [promptKey: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    func start() {
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            self?.scan()
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func scan() {
        let trusted = isTrusted
        if previousTrust != trusted {
            previousTrust = trusted
            onTrustChange(trusted)
        }
        guard trusted else {
            publish(false)
            publishActivity(false, label: nil)
            return
        }
        let applications = NSWorkspace.shared.runningApplications.filter {
            guard let bundleIdentifier = $0.bundleIdentifier else { return false }
            return appBundleIdentifiers.contains(bundleIdentifier)
        }
        var activityLabel: String?
        let waiting = applications.contains { application in
            var budget = 3000
            let root = AXUIElementCreateApplication(application.processIdentifier)
            guard containsChatMarker(root, budget: &budget) else { return false }
            budget = 3000
            if activityLabel == nil {
                activityLabel = matchingActivityControl(root, budget: &budget)
            }
            budget = 3000
            return containsPromptControl(root, budget: &budget)
        }
        publish(waiting)
        if activityLabel == nil {
            for application in applications {
                var budget = 3000
                let root = AXUIElementCreateApplication(application.processIdentifier)
                guard containsChatMarker(root, budget: &budget) else { continue }
                budget = 3000
                if let match = matchingActivityControl(root, budget: &budget) {
                    activityLabel = match
                    break
                }
            }
        }
        publishActivity(activityLabel != nil, label: activityLabel)
    }

    private func publish(_ waiting: Bool) {
        guard waiting != previousValue else { return }
        previousValue = waiting
        onChange(waiting)
    }

    private func publishActivity(_ active: Bool, label: String?) {
        guard active != previousActivity else { return }
        previousActivity = active
        onActivityChange(active, label)
    }

    private func containsChatMarker(_ element: AXUIElement, budget: inout Int) -> Bool {
        guard budget > 0 else { return false }
        budget -= 1

        let labels = [
            stringAttribute(element, kAXTitleAttribute),
            stringAttribute(element, kAXDescriptionAttribute),
            stringAttribute(element, kAXIdentifierAttribute)
        ].compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
        if labels.contains(where: { label in
            label.contains("copilot") || label == "chat" || label.contains("chat view")
        }) {
            return true
        }
        return children(of: element).contains {
            containsChatMarker($0, budget: &budget)
        }
    }

    private func containsPromptControl(_ element: AXUIElement, budget: inout Int) -> Bool {
        guard budget > 0 else { return false }
        budget -= 1
        let role = stringAttribute(element, kAXRoleAttribute)
        let enabled = boolAttribute(element, kAXEnabledAttribute) ?? true
        let labels = [
            stringAttribute(element, kAXTitleAttribute),
            stringAttribute(element, kAXDescriptionAttribute),
            stringAttribute(element, kAXIdentifierAttribute)
        ].compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }

        if enabled, role == kAXButtonRole as String,
           labels.contains(where: { confirmationLabels.contains($0) }) {
            return true
        }
        if enabled, role == kAXTextFieldRole as String,
           labels.contains(where: {
               $0.contains("answer") || $0.contains("response") || $0.contains("provide input")
           }) {
            return true
        }
        return children(of: element).contains {
            containsPromptControl($0, budget: &budget)
        }
    }

    private func matchingActivityControl(_ element: AXUIElement, budget: inout Int) -> String? {
        guard budget > 0 else { return nil }
        budget -= 1
        let role = stringAttribute(element, kAXRoleAttribute)
        let enabled = boolAttribute(element, kAXEnabledAttribute) ?? true
        let labels = [
            stringAttribute(element, kAXTitleAttribute),
            stringAttribute(element, kAXDescriptionAttribute),
            stringAttribute(element, kAXIdentifierAttribute)
        ].compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
        if enabled, role == kAXButtonRole as String,
           let match = labels.first(where: isCopilotActivityControlLabel) {
            return match
        }
        for child in children(of: element) {
            if let match = matchingActivityControl(child, budget: &budget) {
                return match
            }
        }
        return nil
    }

    private func children(of element: AXUIElement) -> [AXUIElement] {
        var childrenValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &childrenValue) == .success else {
            return []
        }
        return childrenValue as? [AXUIElement] ?? []
    }

    private func stringAttribute(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value as? String
    }

    private func boolAttribute(_ element: AXUIElement, _ attribute: String) -> Bool? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value as? Bool
    }
}
