//
//  ClaudeBridge.swift
//  boringNotch
//
//  Receives Claude Code HTTP hooks on 127.0.0.1 and surfaces them in the notch:
//  permission requests (allow / deny), AskUserQuestion prompts (pick an answer),
//  finished turns (optional reply) and other notifications.
//
//  The listener is event-driven: it costs nothing while idle.
//

import AppKit
import Combine
import Defaults
import Foundation
import Network

struct ClaudeQuestion: Identifiable {
    let id = UUID()
    let question: String
    let header: String
    let options: [String]
    let multiSelect: Bool
}

struct ClaudeItem: Identifiable {
    enum Kind {
        case permission(tool: String, summary: String)
        case question([ClaudeQuestion])
        case finished(message: String, replyDeadline: Date?)
        case notice(message: String)
    }

    let id = UUID()
    let kind: Kind
    let project: String
    let createdAt = Date()
    /// Original hook payload, needed to echo AskUserQuestion input back.
    let payload: [String: Any]

    var needsAnswer: Bool {
        switch kind {
        case .permission, .question: return true
        case .finished(_, let deadline): return deadline != nil
        case .notice: return false
        }
    }
}

extension Notification.Name {
    static let claudeBridgeOpenNotch = Notification.Name("claudeBridgeOpenNotch")
    static let claudeBridgeCloseNotch = Notification.Name("claudeBridgeCloseNotch")
}

@MainActor
final class ClaudeBridge: ObservableObject {
    static let shared = ClaudeBridge()
    static let port: UInt16 = 47821
    /// Must match the Stop hook's `timeout` in ~/.claude/settings.json.
    static let stopHookTimeout: TimeInterval = 120

    /// Apps where the user is already looking at Claude; we stay quiet then.
    private static let claudeFrontApps: Set<String> = [
        "com.anthropic.claudefordesktop",
        "com.apple.Terminal",
        "com.googlecode.iterm2",
        "com.mitchellh.ghostty",
        "dev.warp.Warp-Stable",
        "com.microsoft.VSCode",
    ]

    @Published private(set) var items: [ClaudeItem] = []
    /// Read by the notch window to allow keyboard focus for the reply field.
    static var allowsKeyWindow = false

    private var listener: NWListener?
    private var responders: [UUID: (String) -> Void] = [:]
    private var timeouts: [UUID: Task<Void, Never>] = [:]
    private var defaultsCancellable: AnyCancellable?

    var holdsNotchOpen: Bool { items.contains { $0.needsAnswer } }

    private init() {
        defaultsCancellable = Defaults.publisher(.claudeBridgeEnabled)
            .sink { [weak self] change in
                Task { @MainActor in
                    if change.newValue {
                        self?.start()
                    } else {
                        self?.stop()
                    }
                }
            }
    }

    // MARK: - Listener

    func start() {
        guard listener == nil else { return }
        do {
            let params = NWParameters.tcp
            params.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: Self.port)!)
            params.allowLocalEndpointReuse = true
            let listener = try NWListener(using: params)
            listener.newConnectionHandler = { connection in
                Task { @MainActor in ClaudeBridge.shared.accept(connection) }
            }
            listener.stateUpdateHandler = { state in
                if case .failed(let error) = state {
                    print("[ClaudeBridge] listener failed: \(error)")
                    Task { @MainActor in ClaudeBridge.shared.stop() }
                }
            }
            listener.start(queue: .main)
            self.listener = listener
        } catch {
            print("[ClaudeBridge] could not start listener: \(error)")
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
        for id in Array(responders.keys) { resolve(id, body: "") }
        items.removeAll()
    }

    private func accept(_ connection: NWConnection) {
        connection.start(queue: .main)
        receive(on: connection, buffer: Data())
    }

    private func receive(on connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 256 * 1024) { data, _, isComplete, error in
            Task { @MainActor in
                var buffer = buffer
                if let data { buffer.append(data) }
                if let request = Self.parseRequest(buffer) {
                    ClaudeBridge.shared.handle(request, on: connection)
                } else if isComplete || error != nil || buffer.count > 1_000_000 {
                    connection.cancel()
                } else {
                    ClaudeBridge.shared.receive(on: connection, buffer: buffer)
                }
            }
        }
    }

    /// Returns the JSON body once the full HTTP request has arrived.
    private static func parseRequest(_ data: Data) -> [String: Any]? {
        guard let headerEnd = data.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let header = String(decoding: data[..<headerEnd.lowerBound], as: UTF8.self)
        var length = 0
        for line in header.split(separator: "\r\n") {
            let parts = line.split(separator: ":", maxSplits: 1)
            if parts.count == 2, parts[0].lowercased() == "content-length" {
                length = Int(parts[1].trimmingCharacters(in: .whitespaces)) ?? 0
            }
        }
        let body = data[headerEnd.upperBound...]
        guard body.count >= length else { return nil }
        let json = try? JSONSerialization.jsonObject(with: body.prefix(length))
        return json as? [String: Any] ?? [:]
    }

    private func send(_ body: String, on connection: NWConnection) {
        let bytes = Data(body.utf8)
        let head = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: \(bytes.count)\r\nConnection: close\r\n\r\n"
        connection.send(content: Data(head.utf8) + bytes, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    // MARK: - Hook handling

    private func handle(_ payload: [String: Any], on connection: NWConnection) {
        let event = payload["hook_event_name"] as? String ?? ""
        let project = (payload["cwd"] as? String).map { URL(fileURLWithPath: $0).lastPathComponent } ?? "Claude"
        let userIsWatchingClaude = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
            .map { Self.claudeFrontApps.contains($0) } ?? false

        // Looking at Claude already: let its own UI handle everything.
        guard !userIsWatchingClaude else {
            send("", on: connection)
            return
        }

        switch event {
        case "PermissionRequest":
            let tool = payload["tool_name"] as? String ?? "Tool"
            let input = payload["tool_input"] as? [String: Any] ?? [:]
            enqueue(ClaudeItem(kind: .permission(tool: tool, summary: Self.summarize(tool: tool, input: input)),
                               project: project, payload: payload),
                    connection: connection, timeout: 280)

        case "PreToolUse":
            let input = payload["tool_input"] as? [String: Any] ?? [:]
            let questions = (input["questions"] as? [[String: Any]] ?? []).map { q in
                ClaudeQuestion(
                    question: q["question"] as? String ?? "",
                    header: q["header"] as? String ?? "",
                    options: (q["options"] as? [[String: Any]] ?? []).compactMap { $0["label"] as? String },
                    multiSelect: q["multiSelect"] as? Bool ?? false
                )
            }
            guard payload["tool_name"] as? String == "AskUserQuestion", !questions.isEmpty else {
                send("", on: connection)
                return
            }
            enqueue(ClaudeItem(kind: .question(questions), project: project, payload: payload),
                    connection: connection, timeout: 280)

        case "Stop":
            let message = Self.trim(payload["last_assistant_message"] as? String ?? "Finished.")
            let window = min(Defaults[.claudeReplyWindow], Int(Self.stopHookTimeout) - 15)
            if window > 0 {
                let deadline = Date().addingTimeInterval(TimeInterval(window))
                enqueue(ClaudeItem(kind: .finished(message: message, replyDeadline: deadline),
                                   project: project, payload: payload),
                        connection: connection, timeout: TimeInterval(window))
            } else {
                send("", on: connection)
                showNotice(ClaudeItem(kind: .finished(message: message, replyDeadline: nil),
                                      project: project, payload: payload))
            }

        case "Notification":
            send("", on: connection)
            let type = payload["notification_type"] as? String ?? ""
            // PermissionRequest / Stop already cover these.
            guard !["permission_prompt", "idle_prompt", "auth_success"].contains(type) else { return }
            let message = payload["message"] as? String ?? "Claude needs your attention."
            showNotice(ClaudeItem(kind: .notice(message: message), project: project, payload: payload))

        default:
            send("", on: connection)
        }
    }

    private func enqueue(_ item: ClaudeItem, connection: NWConnection, timeout: TimeInterval) {
        responders[item.id] = { [weak self] body in
            self?.send(body, on: connection)
        }
        // If Claude gives up (Esc, timeout) it closes the connection: drop the card.
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1) { _, _, isComplete, error in
            guard isComplete || error != nil else { return }
            Task { @MainActor in ClaudeBridge.shared.dismiss(item.id) }
        }
        timeouts[item.id] = Task { [weak self] in
            try? await Task.sleep(for: .seconds(timeout))
            guard !Task.isCancelled else { return }
            self?.resolve(item.id, body: "")
        }
        items.append(item)
        NotificationCenter.default.post(name: .claudeBridgeOpenNotch, object: nil)
    }

    /// Shows a short notice raised elsewhere in the app (e.g. the usage quota).
    func postNotice(_ message: String, source: String, duration: TimeInterval = 6) {
        showNotice(ClaudeItem(kind: .notice(message: message), project: source, payload: [:]), duration: duration)
    }

    private func showNotice(_ item: ClaudeItem, duration: TimeInterval = 6) {
        items.removeAll { !$0.needsAnswer }
        items.append(item)
        NotificationCenter.default.post(name: .claudeBridgeOpenNotch, object: nil)
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(duration))
            self?.dismiss(item.id)
        }
    }

    // MARK: - Answers

    func allow(_ item: ClaudeItem) {
        resolve(item.id, body: Self.json(["hookSpecificOutput": [
            "hookEventName": "PermissionRequest",
            "decision": ["behavior": "allow"],
        ]]))
    }

    func deny(_ item: ClaudeItem) {
        resolve(item.id, body: Self.json(["hookSpecificOutput": [
            "hookEventName": "PermissionRequest",
            "decision": ["behavior": "deny", "message": "The user denied this from the notch."],
        ]]))
    }

    /// `answers` maps question text to the chosen label(s), comma-joined for multi-select.
    func answer(_ item: ClaudeItem, answers: [String: String]) {
        var input = item.payload["tool_input"] as? [String: Any] ?? [:]
        input["answers"] = answers
        resolve(item.id, body: Self.json(["hookSpecificOutput": [
            "hookEventName": "PreToolUse",
            "permissionDecision": "allow",
            "updatedInput": input,
        ]]))
    }

    /// Sends text back to Claude as its next instruction by blocking the Stop.
    func reply(_ item: ClaudeItem, text: String) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return resolve(item.id, body: "") }
        resolve(item.id, body: Self.json(["decision": "block", "reason": "The user replied from the notch: \(text)"]))
    }

    /// The user started typing a reply: hold the Stop until the hook's own limit.
    func keepForReply(_ item: ClaudeItem) {
        guard responders[item.id] != nil else { return }
        timeouts[item.id]?.cancel()
        let remaining = max(5, Self.stopHookTimeout - 10 - Date().timeIntervalSince(item.createdAt))
        timeouts[item.id] = Task { [weak self] in
            try? await Task.sleep(for: .seconds(remaining))
            guard !Task.isCancelled else { return }
            self?.resolve(item.id, body: "")
        }
    }

    /// Releases the request so Claude shows its own prompt instead.
    func answerInClaude(_ item: ClaudeItem) {
        resolve(item.id, body: "")
    }

    func dismiss(_ id: UUID) {
        if responders[id] != nil {
            resolve(id, body: "")
        } else {
            remove(id)
        }
    }

    private func resolve(_ id: UUID, body: String) {
        timeouts.removeValue(forKey: id)?.cancel()
        responders.removeValue(forKey: id)?(body)
        remove(id)
    }

    private func remove(_ id: UUID) {
        let before = items.count
        items.removeAll { $0.id == id }
        if before > 0 && items.isEmpty {
            Self.releaseKeyboard()
            NotificationCenter.default.post(name: .claudeBridgeCloseNotch, object: nil)
        }
    }

    // MARK: - Helpers

    /// Hands keyboard focus back to whatever app the user was in.
    static func releaseKeyboard() {
        guard allowsKeyWindow else { return }
        allowsKeyWindow = false
        if let window = NSApp.keyWindow as? BoringNotchSkyLightWindow {
            window.resignKey()
            NSApp.deactivate()
        }
    }

    private static func summarize(tool: String, input: [String: Any]) -> String {
        for key in ["command", "file_path", "url", "pattern", "path", "description"] {
            if let value = input[key] as? String, !value.isEmpty { return trim(value) }
        }
        return trim(json(input))
    }

    private static func trim(_ text: String, limit: Int = 280) -> String {
        let flat = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return flat.count > limit ? String(flat.prefix(limit)) + "…" : flat
    }

    private static func json(_ object: Any) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: object) else { return "" }
        return String(decoding: data, as: UTF8.self)
    }
}
