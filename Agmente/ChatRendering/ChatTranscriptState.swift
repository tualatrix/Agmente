import Foundation
import SwiftUI
import Observation
import ACP
import ACPClient

@MainActor
@Observable
final class ChatTranscriptState {
    var isAtBottom: Bool = true

    @ObservationIgnored
    weak var listView: HighPerformanceChatListView?

    func scrollToBottom(animated: Bool = true) {
        listView?.scrollToBottom(animated: animated)
    }
}

struct ChatEntryActionHandlers {
    var onACPPermissionResponse: ((ACP.ID, String) -> Void)?
    var onJSONRPCPermissionResponse: ((JSONRPCID, String) -> Void)?
    var onApproveRequest: ((JSONRPCID, Bool?) -> Void)?
    var onDeclineRequest: ((JSONRPCID) -> Void)?
    var onUndoFileChanges: (() -> Void)?
    var onReviewFileChanges: (([FileChangeSummaryItem]) -> Void)?

    static let none = ChatEntryActionHandlers()
}

struct ChatRendererConfig {
    var autoScrollTolerance: CGFloat = 4
    var maxMarkdownCharacters: Int = 20000
    var enablePerformanceLogging: Bool = false

    static let `default` = ChatRendererConfig()
}
