//
//  ClaudeBridgeView.swift
//  boringNotch
//
//  Shows the oldest Claude item that needs an answer (or the latest notice).
//

import SwiftUI

struct ClaudeBridgeView: View {
    @ObservedObject private var bridge = ClaudeBridge.shared

    private var current: ClaudeItem? {
        bridge.items.first { $0.needsAnswer } ?? bridge.items.last
    }

    var body: some View {
        Group {
            if let item = current {
                ClaudeItemCard(item: item, queued: bridge.items.filter(\.needsAnswer).count - 1)
                    .id(item.id)
            } else {
                Text("Nothing from Claude right now")
                    .font(.system(size: 13, weight: .medium, design: .rounded))
                    .foregroundStyle(.gray)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .padding(.horizontal, 6)
        .padding(.top, 4)
        .padding(.bottom, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct ClaudeItemCard: View {
    let item: ClaudeItem
    let queued: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            content
        }
        .padding(10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.white.opacity(0.08), lineWidth: 1))
    }

    private var header: some View {
        HStack(spacing: 7) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.orange)
            Text(title)
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundStyle(.white)
            Text(item.project)
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .foregroundStyle(.gray)
                .lineLimit(1)
            Spacer(minLength: 0)
            if queued > 0 {
                Text("+\(queued) more")
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(.gray)
            }
            Button {
                ClaudeBridge.shared.answerInClaude(item)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .frame(width: 18, height: 18)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.gray)
            .help(item.needsAnswer ? "Answer in Claude instead" : "Dismiss")
        }
    }

    @ViewBuilder
    private var content: some View {
        switch item.kind {
        case .permission(let tool, let summary):
            PermissionContent(item: item, tool: tool, summary: summary)
        case .question(let questions):
            QuestionContent(item: item, questions: questions)
        case .finished(let message, let deadline):
            FinishedContent(item: item, message: message, deadline: deadline)
        case .notice(let message):
            BodyText(message, lines: 5)
        }
    }

    private var icon: String {
        switch item.kind {
        case .permission: return "lock.shield"
        case .question: return "questionmark.bubble"
        case .finished: return "checkmark.circle"
        case .notice: return "bell"
        }
    }

    private var title: String {
        switch item.kind {
        case .permission(let tool, _): return "Allow \(tool)?"
        case .question: return "Claude is asking"
        case .finished: return "Claude finished"
        case .notice: return "Claude"
        }
    }
}

private struct BodyText: View {
    let text: String
    let lines: Int

    init(_ text: String, lines: Int) {
        self.text = text
        self.lines = lines
    }

    var body: some View {
        Text(text)
            .font(.system(size: 12, design: .rounded))
            .foregroundStyle(.white.opacity(0.85))
            .lineLimit(lines)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct PillButton: View {
    let label: String
    var prominent = false
    var tint: Color = .white
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .lineLimit(1)
                .padding(.horizontal, 12)
                .padding(.vertical, 5)
                .background(prominent ? tint.opacity(0.9) : Color.white.opacity(0.12), in: Capsule())
                .foregroundStyle(prominent ? .black : .white)
        }
        .buttonStyle(.plain)
    }
}

private struct PermissionContent: View {
    let item: ClaudeItem
    let tool: String
    let summary: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(summary)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.white.opacity(0.85))
                .lineLimit(4)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(6)
                .background(Color.black.opacity(0.4), in: RoundedRectangle(cornerRadius: 6))
            Spacer(minLength: 0)
            HStack(spacing: 8) {
                PillButton(label: "Deny") { ClaudeBridge.shared.deny(item) }
                PillButton(label: "Answer in Claude") { ClaudeBridge.shared.answerInClaude(item) }
                Spacer(minLength: 0)
                PillButton(label: "Allow", prominent: true, tint: .green) { ClaudeBridge.shared.allow(item) }
            }
        }
    }
}

private struct QuestionContent: View {
    let item: ClaudeItem
    let questions: [ClaudeQuestion]

    @State private var index = 0
    @State private var answers: [String: String] = [:]
    @State private var picked: Set<String> = []

    var body: some View {
        let question = questions[index]
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                BodyText(question.question, lines: 2)
                if questions.count > 1 {
                    Text("\(index + 1)/\(questions.count)")
                        .font(.system(size: 11, design: .rounded))
                        .foregroundStyle(.gray)
                }
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(question.options, id: \.self) { option in
                        PillButton(label: option, prominent: picked.contains(option), tint: .orange) {
                            choose(option, in: question)
                        }
                    }
                }
            }
            Spacer(minLength: 0)
            if question.multiSelect {
                HStack {
                    Spacer()
                    PillButton(label: "Done", prominent: !picked.isEmpty, tint: .green) {
                        guard !picked.isEmpty else { return }
                        record(question.options.filter(picked.contains).joined(separator: ", "), for: question)
                    }
                }
            }
        }
    }

    private func choose(_ option: String, in question: ClaudeQuestion) {
        if question.multiSelect {
            if picked.contains(option) { picked.remove(option) } else { picked.insert(option) }
        } else {
            record(option, for: question)
        }
    }

    private func record(_ answer: String, for question: ClaudeQuestion) {
        answers[question.question] = answer
        picked = []
        if index + 1 < questions.count {
            index += 1
        } else {
            ClaudeBridge.shared.answer(item, answers: answers)
        }
    }
}

private struct FinishedContent: View {
    let item: ClaudeItem
    let message: String
    let deadline: Date?

    @State private var reply = ""
    @State private var typing = false
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            BodyText(message, lines: deadline == nil ? 5 : 3)
            Spacer(minLength: 0)
            if let deadline {
                HStack(spacing: 8) {
                    TextField("Reply to Claude…", text: $reply)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12, design: .rounded))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(Color.white.opacity(0.12), in: Capsule())
                        .focused($focused)
                        .onSubmit(send)
                        .onChange(of: focused) { _, isFocused in
                            if isFocused { beginTyping() }
                        }
                    if !typing {
                        // Stop the countdown once the user starts a reply.
                        Text(deadline, style: .timer)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.gray)
                    }
                    PillButton(label: "Send", prominent: !reply.isEmpty, tint: .orange, action: send)
                    PillButton(label: "Done") { ClaudeBridge.shared.answerInClaude(item) }
                }
            }
        }
        // Let a click on the reply field make the notch the key window.
        .onAppear { if deadline != nil { ClaudeBridge.allowsKeyWindow = true } }
        .onDisappear { ClaudeBridge.releaseKeyboard() }
    }

    private func beginTyping() {
        guard !typing else { return }
        typing = true
        ClaudeBridge.shared.keepForReply(item)
    }

    private func send() {
        ClaudeBridge.shared.reply(item, text: reply)
    }
}
