import Foundation
import SwiftUI
import Observation
#if canImport(UIKit)
import ACP
import ACPClient
#endif

@MainActor
protocol ChatTranscriptScrollable: AnyObject {
    func scrollToBottom(animated: Bool)
}

@MainActor
@Observable
final class ChatTranscriptState {
    var isAtBottom: Bool = true

    @ObservationIgnored
    weak var listView: (any ChatTranscriptScrollable)?

    func scrollToBottom(animated: Bool = true) {
        listView?.scrollToBottom(animated: animated)
    }
}

#if canImport(UIKit)
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
#endif
