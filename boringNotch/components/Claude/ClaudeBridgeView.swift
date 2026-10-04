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
    @EnvironmentObject private var vm: BoringViewModel
    let item: ClaudeItem
    let queued: Int

    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            content
        }
        .padding(10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.white.opacity(0.08), lineWidth: 1))
        // Answered, dismissed or switched away: shrink the notch back.
        .onDisappear { vm.setExpanded(false) }
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
            if isExpandable {
                Button {
                    expanded.toggle()
                    vm.setExpanded(expanded)
                    // Reading a long reply shouldn't let the reply window run out.
                    if expanded, case .finished(_, let deadline) = item.kind, deadline != nil {
                        ClaudeBridge.shared.keepForReply(item)
                    }
                } label: {
                    Image(systemName: expanded ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
                        .font(.system(size: 10, weight: .bold))
                        .frame(width: 18, height: 18)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.gray)
                .help(expanded ? "Collapse" : "Show the full message")
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
            PermissionContent(item: item, tool: tool, summary: summary, expanded: expanded)
        case .question(let questions):
            QuestionContent(item: item, questions: questions)
        case .finished(let message, let deadline):
            FinishedContent(item: item, message: message, deadline: deadline, expanded: expanded)
        case .notice(let message):
            MessageText(item: item, text: message, lines: 5, expanded: expanded)
        case .handoff(let message):
            HandoffContent(item: item, message: message)
        }
    }

    private var isExpandable: Bool {
        switch item.kind {
        case .permission, .finished, .notice: return true
        case .question, .handoff: return false
        }
    }

    private var icon: String {
        switch item.kind {
        case .permission: return "lock.shield"
        case .question: return "questionmark.bubble"
        case .finished: return "checkmark.circle"
        case .notice: return "bell"
        case .handoff: return "arrow.up.forward.app"
        }
    }

    private var title: String {
        switch item.kind {
        case .permission(let tool, _): return "Allow \(tool)?"
        case .question: return "Claude is asking"
        case .finished: return "Claude finished"
        case .notice: return "Claude"
        case .handoff: return "Claude needs you"
        }
    }
}

/// Message text that opens its chat when clicked. Collapsed it shows a few lines;
/// expanded it shows everything, scrolling inside the card.
private struct MessageText: View {
    let item: ClaudeItem
    let text: String
    let lines: Int
    let expanded: Bool
    var monospaced = false

    var body: some View {
        Group {
            if expanded {
                ScrollView(.vertical) {
                    label(lineLimit: nil)
                }
                .scrollIndicators(.automatic)
            } else {
                label(lineLimit: lines)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { ClaudeBridge.shared.openInClaude(item) }
        .help("Open this chat in Claude")
    }

    private func label(lineLimit: Int?) -> some View {
        Text(text)
            .font(monospaced ? .system(size: 11, design: .monospaced) : .system(size: 12, design: .rounded))
            .foregroundStyle(.white.opacity(0.85))
            .lineLimit(lineLimit)
            .frame(maxWidth: .infinity, alignment: .leading)
            .textSelection(.disabled)
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
    let expanded: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            MessageText(item: item, text: summary, lines: 4, expanded: expanded, monospaced: true)
                .padding(6)
                .background(Color.black.opacity(0.4), in: RoundedRectangle(cornerRadius: 6))
            if !expanded { Spacer(minLength: 0) }
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
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top) {
                MessageText(item: item, text: question.question, lines: 2, expanded: false)
                if questions.count > 1 {
                    Text("\(index + 1)/\(questions.count)")
                        .font(.system(size: 11, design: .rounded))
                        .foregroundStyle(.gray)
                }
            }
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(question.options, id: \.self) { option in
                        OptionRow(
                            option: option,
                            multiSelect: question.multiSelect,
                            selected: picked.contains(option.label)
                        ) {
                            choose(option.label, in: question)
                        }
                    }
                }
            }
            .scrollIndicators(.automatic)
            HStack(spacing: 8) {
                // Claude's own prompt also takes a typed answer ("Other").
                PillButton(label: "Other… in Claude") { ClaudeBridge.shared.openInClaude(item) }
                Spacer(minLength: 0)
                if question.multiSelect {
                    PillButton(label: "Done", prominent: !picked.isEmpty, tint: .green) {
                        guard !picked.isEmpty else { return }
                        let labels = question.options.map(\.label).filter(picked.contains)
                        record(labels.joined(separator: ", "), for: question)
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

private struct OptionRow: View {
    let option: ClaudeOption
    let multiSelect: Bool
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: multiSelect ? (selected ? "checkmark.square.fill" : "square") : "circle")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(selected ? .orange : .gray)
                    .padding(.top, 2)
                VStack(alignment: .leading, spacing: 1) {
                    Text(option.label)
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white)
                    if !option.description.isEmpty {
                        Text(option.description)
                            .font(.system(size: 10, design: .rounded))
                            .foregroundStyle(.gray)
                            .lineLimit(2)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(Color.white.opacity(selected ? 0.16 : 0.08), in: RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

private struct HandoffContent: View {
    let item: ClaudeItem
    let message: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            MessageText(item: item, text: message, lines: 3, expanded: false)
            Text("Open in Claude to continue.")
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundStyle(.orange)
            Spacer(minLength: 0)
            HStack {
                Spacer(minLength: 0)
                PillButton(label: "Open in Claude", prominent: true, tint: .orange) {
                    ClaudeBridge.shared.openInClaude(item)
                }
            }
        }
    }
}

private struct FinishedContent: View {
    let item: ClaudeItem
    let message: String
    let deadline: Date?
    let expanded: Bool

    @State private var reply = ""
    @State private var typing = false
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            MessageText(item: item, text: message, lines: deadline == nil ? 5 : 3, expanded: expanded)
            if !expanded { Spacer(minLength: 0) }
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
