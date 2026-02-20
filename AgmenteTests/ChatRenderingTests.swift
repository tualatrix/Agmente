import Foundation
import Testing
@testable import Agmente

struct ChatRenderingTests {

    @Test func entryMapperGeneratesExpectedKinds() {
        let user = ChatMessage(role: .user, content: "hello", isStreaming: false)

        let assistant = ChatMessage(
            role: .assistant,
            content: "",
            isStreaming: true,
            segments: [
                AssistantSegment(kind: .message, text: "answer"),
                AssistantSegment(kind: .thought, text: "thinking"),
            ]
        )

        let mapper = ChatEntryMapper()
        let entries = mapper.entries(from: [user, assistant])

        #expect(entries.contains(where: { $0.kind == .userText }))
        #expect(entries.contains(where: { $0.kind == .assistantMarkdown }))
        #expect(entries.contains(where: { $0.kind == .assistantThought }))
        #expect(entries.contains(where: { $0.kind == .streamingIndicator }))
    }

    @Test func entryMapperExtractsFileChangeSummary() {
        let toolCall = ToolCallDisplay(
            toolCallId: "tc1",
            title: "Edit: Sources/File.swift",
            kind: "edit",
            status: "completed",
            output: "@@ -1 +1 @@\n-old\n+new"
        )
        let assistant = ChatMessage(
            role: .assistant,
            content: "",
            isStreaming: false,
            segments: [AssistantSegment(kind: .toolCall, text: toolCall.title, toolCall: toolCall)]
        )

        let mapper = ChatEntryMapper()
        let entries = mapper.entries(from: [assistant])

        #expect(entries.contains(where: { $0.kind == .fileChanges }))
    }

    @Test func renderDiffDetectsInsertUpdateRemove() {
        let oldEntries: [ChatEntry] = [
            .userText(messageId: UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!, text: "a"),
            .system(messageId: UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!, text: "b", isError: false),
        ]
        let newEntries: [ChatEntry] = [
            .userText(messageId: UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!, text: "a updated"),
            .assistantMarkdown(
                messageId: UUID(uuidString: "CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC")!,
                segmentId: UUID(uuidString: "DDDDDDDD-DDDD-DDDD-DDDD-DDDDDDDDDDDD")!,
                text: "new"
            ),
        ]

        let diff = ChatRenderDiff.make(old: oldEntries, new: newEntries)

        #expect(diff.updated.count == 1)
        #expect(diff.inserted.count == 1)
        #expect(diff.removed.count == 1)
    }
}
