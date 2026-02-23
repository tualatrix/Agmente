import Foundation

/// Token usage breakdown for a specific scope (total or last turn)
public struct AppServerTokenUsageBreakdown: Equatable, Sendable {
    public let totalTokens: Int
    public let inputTokens: Int
    public let cachedInputTokens: Int
    public let outputTokens: Int
    public let reasoningOutputTokens: Int
    
    public init(
        totalTokens: Int = 0,
        inputTokens: Int = 0,
        cachedInputTokens: Int = 0,
        outputTokens: Int = 0,
        reasoningOutputTokens: Int = 0
    ) {
        self.totalTokens = totalTokens
        self.inputTokens = inputTokens
        self.cachedInputTokens = cachedInputTokens
        self.outputTokens = outputTokens
        self.reasoningOutputTokens = reasoningOutputTokens
    }
    
    /// Calculate the percentage of context window used
    public func usagePercentage(contextWindow: Int?) -> Double {
        guard let contextWindow = contextWindow, contextWindow > 0 else { return 0 }
        return min(100.0, Double(totalTokens) / Double(contextWindow) * 100)
    }
    
    /// Format token count for display (e.g., "1.2K" for 1200)
    public var formattedTotalTokens: String {
        formatTokenCount(totalTokens)
    }
    
    private func formatTokenCount(_ count: Int) -> String {
        if count >= 1_000_000 {
            return String(format: "%.1fM", Double(count) / 1_000_000)
        } else if count >= 1_000 {
            return String(format: "%.1fK", Double(count) / 1_000)
        } else {
            return "\(count)"
        }
    }
}

/// Complete token usage information for a thread
public struct AppServerThreadTokenUsage: Equatable, Sendable {
    public let total: AppServerTokenUsageBreakdown
    public let last: AppServerTokenUsageBreakdown
    public let modelContextWindow: Int?
    
    public init(
        total: AppServerTokenUsageBreakdown = AppServerTokenUsageBreakdown(),
        last: AppServerTokenUsageBreakdown = AppServerTokenUsageBreakdown(),
        modelContextWindow: Int? = nil
    ) {
        self.total = total
        self.last = last
        self.modelContextWindow = modelContextWindow
    }
    
    /// Parse from JSON payload received from server
    public init?(json: JSONValue?) {
        guard let object = json?.objectValue else { return nil }
        
        let totalObj = object["total"]?.objectValue
        let lastObj = object["last"]?.objectValue
        let contextWindow = object["modelContextWindow"]?.numberValue.map { Int($0) }
        
        self.total = AppServerTokenUsageBreakdown(
            totalTokens: totalObj?["totalTokens"]?.numberValue.map { Int($0) } ?? 0,
            inputTokens: totalObj?["inputTokens"]?.numberValue.map { Int($0) } ?? 0,
            cachedInputTokens: totalObj?["cachedInputTokens"]?.numberValue.map { Int($0) } ?? 0,
            outputTokens: totalObj?["outputTokens"]?.numberValue.map { Int($0) } ?? 0,
            reasoningOutputTokens: totalObj?["reasoningOutputTokens"]?.numberValue.map { Int($0) } ?? 0
        )
        
        self.last = AppServerTokenUsageBreakdown(
            totalTokens: lastObj?["totalTokens"]?.numberValue.map { Int($0) } ?? 0,
            inputTokens: lastObj?["inputTokens"]?.numberValue.map { Int($0) } ?? 0,
            cachedInputTokens: lastObj?["cachedInputTokens"]?.numberValue.map { Int($0) } ?? 0,
            outputTokens: lastObj?["outputTokens"]?.numberValue.map { Int($0) } ?? 0,
            reasoningOutputTokens: lastObj?["reasoningOutputTokens"]?.numberValue.map { Int($0) } ?? 0
        )
        
        self.modelContextWindow = contextWindow
    }
}

/// Token usage update notification payload
public struct AppServerTokenUsageUpdate: Equatable, Sendable {
    public let threadId: String
    public let turnId: String
    public let tokenUsage: AppServerThreadTokenUsage
    
    public init?(json: JSONValue?) {
        guard let object = json?.objectValue,
              let threadId = object["threadId"]?.stringValue,
              let turnId = object["turnId"]?.stringValue else {
            return nil
        }
        
        self.threadId = threadId
        self.turnId = turnId
        self.tokenUsage = AppServerThreadTokenUsage(json: object["tokenUsage"]) ?? AppServerThreadTokenUsage()
    }
}
