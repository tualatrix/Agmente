#if canImport(UIKit)
import SwiftUI
import UIKit
import MarkdownView

struct ChatTranscriptContainerView: UIViewRepresentable {
    let state: ChatTranscriptState
    let messages: [ChatMessage]
    let contentInsets: UIEdgeInsets
    let actionHandlers: ChatEntryActionHandlers
    var onAtBottomChanged: ((Bool) -> Void)?
    var config: ChatRendererConfig = .default

    final class Coordinator {
        var hasRendered = false
        var lastMessages: [ChatMessage] = []
        var lastInsets: UIEdgeInsets = .zero
        var onAtBottomChanged: ((Bool) -> Void)?
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> HighPerformanceChatListView {
        let view = HighPerformanceChatListView()
        view.config = config
        view.actionHandlers = actionHandlers
        view.updateContentInsets(contentInsets)
        context.coordinator.lastInsets = contentInsets
        context.coordinator.onAtBottomChanged = onAtBottomChanged
        view.onAtBottomChanged = { [weak state] isAtBottom in
            Task { @MainActor in
                state?.isAtBottom = isAtBottom
            }
            context.coordinator.onAtBottomChanged?(isAtBottom)
        }
        state.listView = view
        return view
    }

    func updateUIView(_ uiView: HighPerformanceChatListView, context: Context) {
        uiView.config = config
        uiView.actionHandlers = actionHandlers
        context.coordinator.onAtBottomChanged = onAtBottomChanged
        if context.coordinator.lastInsets != contentInsets {
            uiView.updateContentInsets(contentInsets)
            context.coordinator.lastInsets = contentInsets
        }
        if !context.coordinator.hasRendered || context.coordinator.lastMessages != messages {
            // Keep row diff updates non-animated to avoid alpha flicker under frequent updates.
            uiView.render(messages: messages, animated: false)
            context.coordinator.lastMessages = messages
            context.coordinator.hasRendered = true
        }
        state.listView = uiView
    }
}
#endif
