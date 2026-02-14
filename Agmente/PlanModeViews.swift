import SwiftUI
import ACPClient

// MARK: - Data Models

struct UserInputOption: Equatable, Identifiable {
    let id = UUID()
    let label: String
    let description: String?
    let isOther: Bool
    let isSecret: Bool
}

struct UserInputQuestion: Equatable, Identifiable {
    let id: String
    let header: String
    let text: String
    let options: [UserInputOption]
    let multiSelect: Bool
}

struct PendingUserInputRequest: Equatable, Identifiable {
    var id: String {
        switch requestId {
        case .string(let s): return s
        case .int(let i): return String(i)
        }
    }
    let requestId: JSONRPCID
    let questions: [UserInputQuestion]
    var isSubmitted: Bool = false
}

// MARK: - Proposed Plan Card

struct ProposedPlanCard: View {
    let content: String
    let isStreaming: Bool
    let onImplement: () -> Void
    let onContinuePlanning: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Header
            HStack(spacing: 6) {
                Image(systemName: "doc.text")
                    .font(.footnote.weight(.semibold))
                Text("Proposed Plan")
                    .font(.footnote.weight(.semibold))
            }
            .foregroundStyle(.blue)

            // Plan content
            if !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                MarkdownText(content: content)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            if isStreaming {
                HStack(spacing: 6) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Planning...")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            // Action buttons (shown when not streaming)
            if !isStreaming && !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                HStack(spacing: 10) {
                    Button(action: onImplement) {
                        HStack(spacing: 4) {
                            Image(systemName: "hammer")
                                .font(.caption.weight(.semibold))
                            Text("Implement this plan")
                                .font(.footnote.weight(.medium))
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(Color.blue)
                        .foregroundStyle(.white)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                    .buttonStyle(.plain)

                    Button(action: onContinuePlanning) {
                        Text("Continue planning")
                            .font(.footnote.weight(.medium))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(Color(.systemGray5))
                            .foregroundStyle(.secondary)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 10)
        .background(Color.blue.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}

// MARK: - User Input Question Card

struct UserInputQuestionCard: View {
    let request: PendingUserInputRequest
    let onSubmit: (JSONRPCID, [String: [String]]) -> Void

    @State private var selections: [String: Set<String>] = [:] // questionId -> selected labels
    @State private var otherTexts: [String: String] = [:] // questionId -> free text
    @State private var isSubmitted: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Header
            HStack(spacing: 6) {
                Image(systemName: "questionmark.circle")
                    .font(.footnote.weight(.semibold))
                Text("Question")
                    .font(.footnote.weight(.semibold))
            }
            .foregroundStyle(.orange)

            ForEach(request.questions) { question in
                questionView(for: question)
            }

            if !isSubmitted && !request.isSubmitted {
                Button(action: submitAnswers) {
                    HStack(spacing: 4) {
                        Image(systemName: "paperplane")
                            .font(.caption.weight(.semibold))
                        Text("Submit")
                            .font(.footnote.weight(.medium))
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Color.blue)
                    .foregroundStyle(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 10)
        .background(Color.orange.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    @ViewBuilder
    private func questionView(for question: UserInputQuestion) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if !question.header.isEmpty {
                Text(question.header)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            Text(question.text)
                .font(.callout)

            // Option chips
            FlowLayout(spacing: 6) {
                ForEach(question.options) { option in
                    if option.isOther {
                        otherInputView(for: question, option: option)
                    } else {
                        optionChip(for: question, option: option)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func optionChip(for question: UserInputQuestion, option: UserInputOption) -> some View {
        let isSelected = selections[question.id]?.contains(option.label) ?? false
        let disabled = isSubmitted || request.isSubmitted

        Button {
            guard !disabled else { return }
            var current = selections[question.id] ?? []
            if question.multiSelect {
                if current.contains(option.label) {
                    current.remove(option.label)
                } else {
                    current.insert(option.label)
                }
            } else {
                current = [option.label]
            }
            selections[question.id] = current
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(option.label)
                    .font(.footnote.weight(.medium))
                if let desc = option.description, !desc.isEmpty {
                    Text(desc)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(isSelected ? Color.blue.opacity(0.15) : Color(.systemGray5))
            .foregroundStyle(isSelected ? Color.blue : Color.primary)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(isSelected ? Color.blue.opacity(0.3) : Color.clear, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .opacity(disabled ? 0.6 : 1.0)
    }

    @ViewBuilder
    private func otherInputView(for question: UserInputQuestion, option: UserInputOption) -> some View {
        let disabled = isSubmitted || request.isSubmitted

        VStack(alignment: .leading, spacing: 4) {
            Text(option.label)
                .font(.footnote.weight(.medium))
                .foregroundStyle(.secondary)
            if option.isSecret {
                SecureField("Enter value...", text: Binding(
                    get: { otherTexts[question.id] ?? "" },
                    set: { otherTexts[question.id] = $0 }
                ))
                .font(.footnote)
                .textFieldStyle(.roundedBorder)
                .disabled(disabled)
            } else {
                TextField("Enter value...", text: Binding(
                    get: { otherTexts[question.id] ?? "" },
                    set: { otherTexts[question.id] = $0 }
                ))
                .font(.footnote)
                .textFieldStyle(.roundedBorder)
                .disabled(disabled)
            }
        }
        .frame(maxWidth: 200)
    }

    private func submitAnswers() {
        var answers: [String: [String]] = [:]
        for question in request.questions {
            var selected = Array(selections[question.id] ?? [])
            if let otherText = otherTexts[question.id], !otherText.isEmpty {
                selected.append(otherText)
            }
            if !selected.isEmpty {
                answers[question.id] = selected
            }
        }
        isSubmitted = true
        onSubmit(request.requestId, answers)
    }
}

// FlowLayout is defined in ContentView.swift and shared across the app.
