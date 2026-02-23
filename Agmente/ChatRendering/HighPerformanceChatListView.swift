#if canImport(UIKit)
import UIKit
import ListViewKit
import MarkdownView
import ACP
import ACPClient

private enum RowType {
    case userText
    case userImages
    case assistantMarkdown
    case assistantThought
    case assistantPlan
    case toolCall
    case fileChanges
    case system
    case error
    case streaming
}

private enum MarkdownStyle {
    case assistant
    case thought
    case plan

    var backgroundColor: UIColor {
        switch self {
        case .assistant:
            return UIColor.systemGray6
        case .thought:
            return UIColor.systemGray6
        case .plan:
            return UIColor.systemBlue.withAlphaComponent(0.08)
        }
    }

    var horizontalPadding: CGFloat {
        switch self {
        case .assistant, .thought, .plan:
            return 10
        }
    }

    var verticalPadding: CGFloat {
        switch self {
        case .assistant:
            return 8
        case .thought, .plan:
            return 10
        }
    }
}

final class HighPerformanceChatListView: UIView {
    static let rowInsets = UIEdgeInsets(top: 0, left: 14, bottom: 12, right: 14)
    private static let thoughtExpandedHashSalt = 0x5F3759DF
    private let updateQueue = DispatchQueue(label: "agmente.chat.render.queue", qos: .userInteractive)

    private lazy var listView: ListViewKit.ListView = .init()
    private lazy var dataSource: ListViewDiffableDataSource<ChatEntry> = .init(listView: listView)

    private let mapper = ChatEntryMapper()
    private let markdownCache = ChatMarkdownPackageCache()
    private let heightCache = ChatHeightCache()

    private lazy var sizingLabel: UILabel = {
        let label = UILabel()
        label.numberOfLines = 0
        return label
    }()

    private lazy var sizingMarkdownView: MarkdownTextView = {
        let view = MarkdownTextView()
        view.throttleInterval = 1 / 60
        return view
    }()

    private var rawEntries: [ChatEntry] = []
    private var entries: [ChatEntry] = []
    private var renderedEntries: [ChatEntry] = []
    private var pendingEntries: [ChatEntry]?
    private var pendingEntriesAnimated: Bool = false
    private var expandedThoughtEntryIds: Set<String> = []
    private var isAutoScrollingToBottom = true
    private var autoScrollTolerance: CGFloat = 4
    private var lastReportedAtBottom: Bool?

    var actionHandlers: ChatEntryActionHandlers = .none
    var config: ChatRendererConfig = .default {
        didSet {
            autoScrollTolerance = config.autoScrollTolerance
        }
    }

    var onAtBottomChanged: ((Bool) -> Void)?

    private(set) var theme: MarkdownTheme = .default {
        didSet {
            listView.reloadData()
        }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear

        autoScrollTolerance = config.autoScrollTolerance

        listView.delegate = self
        listView.adapter = self
        listView.backgroundColor = .clear
        listView.alwaysBounceVertical = true
        listView.alwaysBounceHorizontal = false
        listView.showsVerticalScrollIndicator = true
        listView.showsHorizontalScrollIndicator = false
        listView.contentInsetAdjustmentBehavior = .never

        addSubview(listView)
        listView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            listView.leadingAnchor.constraint(equalTo: leadingAnchor),
            listView.trailingAnchor.constraint(equalTo: trailingAnchor),
            listView.topAnchor.constraint(equalTo: topAnchor),
            listView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func setTheme(_ theme: MarkdownTheme) {
        self.theme = theme
    }

    func updateContentInsets(_ insets: UIEdgeInsets) {
        listView.contentInset = insets
        listView.scrollIndicatorInsets = insets
    }

    func render(messages: [ChatMessage], animated: Bool = true) {
        let theme = self.theme
        let thoughtTheme = Self.makeThoughtMarkdownTheme(from: theme)
        updateQueue.async { [weak self] in
            guard let self else { return }
            let newEntries = mapper.entries(from: messages)

            for entry in newEntries where entry.kind == .assistantMarkdown || entry.kind == .assistantThought || entry.kind == .assistantPlan {
                guard !entry.text.isEmpty else { continue }
                let entryTheme = entry.kind == .assistantThought ? thoughtTheme : theme
                _ = markdownCache.package(for: entry.id, content: entry.text, theme: entryTheme)
            }

            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.rawEntries = newEntries
                self.pruneExpandedThoughtState(using: newEntries)
                let visibleEntries = self.visibleEntries(from: newEntries)
                let diff = ChatRenderDiff.make(old: self.renderedEntries, new: visibleEntries)
                if diff.isEmpty {
                    self.flushPendingEntriesIfPossible()
                    return
                }
                self.applyEntries(visibleEntries, animated: animated)
            }
        }
    }

    func scrollToBottom(animated: Bool = true) {
        let target = listView.maximumContentOffset
        if abs(listView.contentOffset.y - target.y) <= 0.5 {
            isAutoScrollingToBottom = true
            reportAtBottomIfChanged(true)
            return
        }
        if animated {
            listView.scroll(to: target)
        } else {
            listView.setContentOffset(target, animated: false)
        }
        isAutoScrollingToBottom = true
        reportAtBottomIfChanged(true)
    }

    private func updateAutoScrollingFromCurrentOffset() {
        let isNearBottom = isContentOffsetNearBottom()
        if isNearBottom {
            isAutoScrollingToBottom = true
        }
        reportAtBottomIfChanged(isNearBottom)
        flushPendingEntriesIfPossible()
    }

    private func isContentOffsetNearBottom() -> Bool {
        abs(listView.contentOffset.y - listView.maximumContentOffset.y) <= autoScrollTolerance
    }

    private func reportAtBottomIfChanged(_ isAtBottom: Bool) {
        guard lastReportedAtBottom != isAtBottom else { return }
        lastReportedAtBottom = isAtBottom
        onAtBottomChanged?(isAtBottom)
    }

    private func isThoughtExpanded(for entry: ChatEntry) -> Bool {
        entry.isStreaming || expandedThoughtEntryIds.contains(entry.id)
    }

    private func pruneExpandedThoughtState(using entries: [ChatEntry]) {
        let validIds = Set(entries.lazy.filter { $0.kind == .assistantThought }.map(\.id))
        expandedThoughtEntryIds.formIntersection(validIds)
    }

    private func visibleEntries(from rawEntries: [ChatEntry]) -> [ChatEntry] {
        rawEntries.map { entry in
            guard entry.kind == .assistantThought else { return entry }
            let expanded = isThoughtExpanded(for: entry)
            if expanded {
                return entry.withContentHashSalt(Self.thoughtExpandedHashSalt)
            }
            return entry
        }
    }

    private func toggleThoughtExpansion(entryId: String) {
        guard let entry = rawEntries.first(where: { $0.id == entryId && $0.kind == .assistantThought }) else {
            return
        }
        guard !entry.isStreaming else { return }

        if expandedThoughtEntryIds.contains(entryId) {
            expandedThoughtEntryIds.remove(entryId)
        } else {
            expandedThoughtEntryIds.insert(entryId)
        }

        let visibleEntries = visibleEntries(from: rawEntries)
        let diff = ChatRenderDiff.make(old: renderedEntries, new: visibleEntries)
        guard !diff.isEmpty else { return }
        heightCache.removeAll()
        applyEntries(visibleEntries, animated: true)
    }

    private func applyEntries(_ visibleEntries: [ChatEntry], animated: Bool) {
        if shouldDeferEntriesApplication() {
            pendingEntries = visibleEntries
            pendingEntriesAnimated = pendingEntriesAnimated || animated
            return
        }

        pendingEntries = nil
        pendingEntriesAnimated = false
        renderedEntries = visibleEntries
        entries = visibleEntries
        dataSource.applySnapshot(using: visibleEntries, animatingDifferences: animated)
        if isAutoScrollingToBottom {
            scrollToBottom(animated: animated)
        }
    }

    private func shouldDeferEntriesApplication() -> Bool {
        if isAutoScrollingToBottom {
            return false
        }
        return listView.isTracking || listView.isDragging || listView.isDecelerating
    }

    private func flushPendingEntriesIfPossible() {
        guard !shouldDeferEntriesApplication() else { return }
        guard let pendingEntries else { return }
        let animated = pendingEntriesAnimated
        self.pendingEntries = nil
        pendingEntriesAnimated = false

        let diff = ChatRenderDiff.make(old: renderedEntries, new: pendingEntries)
        guard !diff.isEmpty else { return }

        renderedEntries = pendingEntries
        entries = pendingEntries
        dataSource.applySnapshot(using: pendingEntries, animatingDifferences: animated)
        if isAutoScrollingToBottom {
            scrollToBottom(animated: animated)
        }
    }

    private func boundingHeight(for text: String, font: UIFont, width: CGFloat, lineLimit: Int = 0) -> CGFloat {
        sizingLabel.font = font
        sizingLabel.numberOfLines = lineLimit
        sizingLabel.text = text
        return ceil(sizingLabel.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height)
    }

    private static func makeThoughtMarkdownTheme(from baseTheme: MarkdownTheme) -> MarkdownTheme {
        var thoughtTheme = baseTheme
        let thoughtBodyFont = baseTheme.fonts.footnote.withWeight(.medium)
        thoughtTheme.align(to: thoughtBodyFont.pointSize)
        thoughtTheme.fonts.body = thoughtBodyFont
        thoughtTheme.fonts.bold = thoughtBodyFont
        thoughtTheme.fonts.italic = thoughtBodyFont
        thoughtTheme.fonts.footnote = thoughtBodyFont
        thoughtTheme.fonts.codeInline = UIFont.monospacedSystemFont(ofSize: thoughtBodyFont.pointSize, weight: .medium)
        thoughtTheme.fonts.code = UIFont.monospacedSystemFont(
            ofSize: ceil(thoughtBodyFont.pointSize * MarkdownTheme.codeScale),
            weight: .medium
        )
        return thoughtTheme
    }
}

extension HighPerformanceChatListView: ChatTranscriptScrollable {}

extension HighPerformanceChatListView: UIScrollViewDelegate {
    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        isAutoScrollingToBottom = false
        reportAtBottomIfChanged(false)
    }

    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        updateAutoScrollingFromCurrentOffset()
    }

    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        if !decelerate {
            updateAutoScrollingFromCurrentOffset()
        }
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        reportAtBottomIfChanged(isContentOffsetNearBottom())
    }
}

extension HighPerformanceChatListView: ListViewAdapter {
    func listView(_ listView: ListViewKit.ListView, rowKindFor item: ItemType, at index: Int) -> RowKind {
        guard let entry = item as? ChatEntry else {
            assertionFailure("Unexpected item type")
            return RowType.system
        }

        switch entry.kind {
        case .userText:
            return RowType.userText
        case .userImages:
            return RowType.userImages
        case .assistantMarkdown:
            return RowType.assistantMarkdown
        case .assistantThought:
            return RowType.assistantThought
        case .assistantPlan:
            return RowType.assistantPlan
        case .toolCall:
            return RowType.toolCall
        case .fileChanges:
            return RowType.fileChanges
        case .system:
            return RowType.system
        case .error:
            return RowType.error
        case .streamingIndicator:
            return RowType.streaming
        }
    }

    func listViewMakeRow(for kind: RowKind) -> ListViewKit.ListRowView {
        guard let kind = kind as? RowType else {
            return ListRowView()
        }

        switch kind {
        case .userText:
            return UserTextRowView()
        case .userImages:
            return UserImagesRowView()
        case .assistantMarkdown:
            return MarkdownRowView(style: .assistant)
        case .assistantThought:
            return ThoughtRowView()
        case .assistantPlan:
            return MarkdownRowView(style: .plan)
        case .toolCall:
            return ToolCallRowView()
        case .fileChanges:
            return FileChangesRowView()
        case .system:
            return SystemRowView(isError: false)
        case .error:
            return SystemRowView(isError: true)
        case .streaming:
            return StreamingIndicatorRowView()
        }
    }

    func listView(_ listView: ListViewKit.ListView, heightFor item: ItemType, at index: Int) -> CGFloat {
        guard let entry = item as? ChatEntry else {
            return 44
        }

        let width = max(0, listView.bounds.width - Self.rowInsets.left - Self.rowInsets.right)
        if width <= 0 {
            return 0
        }

        if let cached = heightCache.height(for: entry, width: width) {
            return cached
        }

        let height: CGFloat
        switch entry.kind {
        case .userText:
            let maxBubbleWidth = max(0, width - 50)
            let textWidth = max(0, maxBubbleWidth - 20)
            let textHeight = boundingHeight(for: entry.text, font: .preferredFont(forTextStyle: .callout), width: textWidth)
            height = textHeight + 14

        case .userImages:
            height = 80

        case .assistantMarkdown:
            sizingMarkdownView.theme = theme
            let package = markdownCache.package(for: entry.id, content: entry.text, theme: theme)
            sizingMarkdownView.setMarkdownManually(package)
            let markdownWidth = max(0, width - (MarkdownStyle.assistant.horizontalPadding * 2))
            let size = sizingMarkdownView.boundingSize(for: markdownWidth)
            height = ceil(size.height) + (MarkdownStyle.assistant.verticalPadding * 2)

        case .assistantPlan:
            sizingMarkdownView.theme = theme
            let package = markdownCache.package(for: entry.id, content: entry.text, theme: theme)
            sizingMarkdownView.setMarkdownManually(package)
            let markdownWidth = max(0, width - (MarkdownStyle.plan.horizontalPadding * 2))
            let size = sizingMarkdownView.boundingSize(for: markdownWidth)
            height = ceil(size.height) + (MarkdownStyle.plan.verticalPadding * 2)

        case .assistantThought:
            let isExpanded = isThoughtExpanded(for: entry)
            if isExpanded {
                let thoughtTheme = Self.makeThoughtMarkdownTheme(from: theme)
                sizingMarkdownView.theme = thoughtTheme
                let package = markdownCache.package(for: entry.id, content: entry.text, theme: thoughtTheme)
                sizingMarkdownView.setMarkdownManually(package)
                let markdownWidth = max(0, width - (ThoughtRowView.horizontalPadding * 2))
                let markdownSize = sizingMarkdownView.boundingSize(for: markdownWidth)
                height = ThoughtRowView.collapsedHeight + ThoughtRowView.contentSpacing + ceil(markdownSize.height) + ThoughtRowView.bottomPadding
            } else {
                height = ThoughtRowView.collapsedHeight
            }

        case .toolCall:
            let payload = ToolCallRowView.Payload(entry: entry)
            height = ToolCallRowView.estimatedHeight(for: payload, width: width)

        case .fileChanges:
            height = FileChangesRowView.estimatedHeight(for: entry.fileChanges, width: width)

        case .system, .error:
            let textHeight = boundingHeight(for: entry.text, font: .preferredFont(forTextStyle: .footnote), width: width - 16)
            height = textHeight + 16

        case .streamingIndicator:
            height = 34
        }

        let finalHeight = height + Self.rowInsets.bottom
        heightCache.store(height: finalHeight, for: entry, width: width)
        return finalHeight
    }

    func listView(_ listView: ListViewKit.ListView, configureRowView rowView: ListViewKit.ListRowView, for item: ItemType, at index: Int) {
        guard let entry = item as? ChatEntry else {
            return
        }

        switch rowView {
        case let row as UserTextRowView:
            row.text = entry.text

        case let row as UserImagesRowView:
            row.images = entry.images

        case let row as MarkdownRowView:
            let package = markdownCache.package(for: entry.id, content: entry.text, theme: theme)
            row.setMarkdown(package, renderToken: "\(entry.id)#\(entry.contentHash)")

        case let row as ThoughtRowView:
            let thoughtTheme = Self.makeThoughtMarkdownTheme(from: theme)
            let package = markdownCache.package(for: entry.id, content: entry.text, theme: thoughtTheme)
            row.configure(
                markdown: package,
                theme: thoughtTheme,
                renderToken: "\(entry.id)#\(entry.contentHash)",
                isExpanded: isThoughtExpanded(for: entry),
                isStreaming: entry.isStreaming,
                onToggle: { [weak self] in
                    self?.toggleThoughtExpansion(entryId: entry.id)
                }
            )

        case let row as ToolCallRowView:
            let payload = ToolCallRowView.Payload(entry: entry)
            row.configure(
                payload: payload,
                onACPPermission: { [weak self] requestId, optionId in
                    self?.actionHandlers.onACPPermissionResponse?(requestId, optionId)
                },
                onJSONRPCPermission: { [weak self] requestId, optionId in
                    self?.actionHandlers.onJSONRPCPermissionResponse?(requestId, optionId)
                },
                onApprove: { [weak self] requestId, acceptForSession in
                    self?.actionHandlers.onApproveRequest?(requestId, acceptForSession)
                },
                onDecline: { [weak self] requestId in
                    self?.actionHandlers.onDeclineRequest?(requestId)
                }
            )

        case let row as FileChangesRowView:
            row.configure(
                items: entry.fileChanges,
                onUndo: { [weak self] in
                    self?.actionHandlers.onUndoFileChanges?()
                },
                onReview: { [weak self] items in
                    self?.actionHandlers.onReviewFileChanges?(items)
                }
            )

        case let row as SystemRowView:
            row.text = entry.text

        case let row as StreamingIndicatorRowView:
            row.text = entry.text

        default:
            break
        }
    }
}

private class BaseRowView: ListRowView {
    let rowContainer = UIView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        addSubview(rowContainer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        rowContainer.frame = CGRect(
            x: HighPerformanceChatListView.rowInsets.left,
            y: 0,
            width: bounds.width - HighPerformanceChatListView.rowInsets.left - HighPerformanceChatListView.rowInsets.right,
            height: bounds.height - HighPerformanceChatListView.rowInsets.bottom
        )
    }
}

private final class UserTextRowView: BaseRowView {
    var text: String = "" {
        didSet {
            label.text = text
            setNeedsLayout()
        }
    }

    private let bubble = UIView()
    private let label = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        bubble.backgroundColor = UIColor.tintColor.withAlphaComponent(0.15)
        bubble.layer.cornerRadius = 12
        bubble.layer.cornerCurve = .continuous
        rowContainer.addSubview(bubble)

        label.numberOfLines = 0
        label.font = .preferredFont(forTextStyle: .callout)
        label.textColor = .label
        bubble.addSubview(label)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let maxWidth = max(0, rowContainer.bounds.width - 50)
        let textSize = label.sizeThatFits(CGSize(width: maxWidth - 20, height: .greatestFiniteMagnitude))
        let bubbleWidth = min(maxWidth, ceil(textSize.width) + 20)
        let bubbleHeight = ceil(textSize.height) + 14
        bubble.frame = CGRect(
            x: rowContainer.bounds.width - bubbleWidth,
            y: 0,
            width: bubbleWidth,
            height: bubbleHeight
        )
        label.frame = bubble.bounds.insetBy(dx: 10, dy: 7)
    }
}

private final class UserImagesRowView: BaseRowView {
    var images: [ChatImageData] = [] {
        didSet {
            rebuildImageViews()
        }
    }

    private var imageViews: [UIImageView] = []

    override init(frame: CGRect) {
        super.init(frame: frame)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        var x = rowContainer.bounds.width
        for imageView in imageViews.reversed() {
            x -= 80
            imageView.frame = CGRect(x: x, y: 0, width: 80, height: 80)
            x -= 6
        }
    }

    private func rebuildImageViews() {
        for view in imageViews {
            view.removeFromSuperview()
        }
        imageViews.removeAll(keepingCapacity: true)

        for image in images {
            let imageView = UIImageView(image: image.thumbnail)
            imageView.contentMode = .scaleAspectFill
            imageView.clipsToBounds = true
            imageView.layer.cornerRadius = 10
            imageView.layer.cornerCurve = .continuous
            imageView.layer.borderWidth = 1
            imageView.layer.borderColor = UIColor.tintColor.withAlphaComponent(0.3).cgColor
            rowContainer.addSubview(imageView)
            imageViews.append(imageView)
        }

        setNeedsLayout()
    }
}

private final class MarkdownRowView: BaseRowView {
    private let style: MarkdownStyle
    private weak var boundScrollView: UIScrollView?
    private var renderedToken: String?

    private let backgroundCard = UIView()
    private let markdownView: MarkdownTextView = {
        let view = MarkdownTextView()
        view.throttleInterval = 1 / 60
        return view
    }()

    init(style: MarkdownStyle) {
        self.style = style
        super.init(frame: .zero)

        backgroundCard.layer.cornerRadius = 12
        backgroundCard.layer.cornerCurve = .continuous
        backgroundCard.backgroundColor = style.backgroundColor
        rowContainer.addSubview(backgroundCard)
        backgroundCard.addSubview(markdownView)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func setMarkdown(_ content: MarkdownTextView.PreprocessedContent, renderToken: String) {
        guard renderedToken != renderToken else { return }
        renderedToken = renderToken
        markdownView.setMarkdown(content)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        backgroundCard.frame = rowContainer.bounds
        markdownView.frame = backgroundCard.bounds.insetBy(dx: style.horizontalPadding, dy: style.verticalPadding)
        let scrollView = superListView
        if boundScrollView !== scrollView {
            boundScrollView = scrollView
            markdownView.bindContentOffset(from: scrollView)
        }
    }
}

private final class ThoughtRowView: BaseRowView {
    static let collapsedHeight: CGFloat = 34
    static let contentSpacing: CGFloat = 3
    static let bottomPadding: CGFloat = 10
    static let horizontalPadding: CGFloat = 14

    private let chip = UIView()
    private let contentContainer = UIView()
    private let markdownView: MarkdownTextView = {
        let view = MarkdownTextView()
        view.throttleInterval = 1 / 60
        return view
    }()
    private let iconView = UIImageView()
    private let titleLabel = UILabel()
    private let chevronView = UIImageView()
    private let headerButton = UIButton(type: .custom)

    private weak var boundScrollView: UIScrollView?
    private var renderedToken: String?
    private var isExpanded: Bool = false
    private var onToggle: (() -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)

        chip.layer.cornerRadius = 16
        chip.layer.cornerCurve = .continuous
        chip.backgroundColor = UIColor.systemPurple.withAlphaComponent(0.08)

        iconView.image = UIImage(systemName: "brain")
        iconView.tintColor = .systemPurple
        iconView.contentMode = .scaleAspectFit

        titleLabel.font = .preferredFont(forTextStyle: .footnote).withWeight(.medium)
        titleLabel.textColor = .systemPurple
        titleLabel.text = "Thinking"

        chevronView.image = UIImage(systemName: "chevron.down")
        chevronView.tintColor = .systemPurple
        chevronView.contentMode = .scaleAspectFit

        headerButton.backgroundColor = .clear
        headerButton.addTarget(self, action: #selector(handleHeaderTap), for: .touchUpInside)
        headerButton.accessibilityLabel = "Thinking"
        headerButton.accessibilityHint = "Expand or collapse details"

        contentContainer.clipsToBounds = true
        contentContainer.addSubview(markdownView)

        rowContainer.addSubview(chip)
        chip.addSubview(iconView)
        chip.addSubview(titleLabel)
        chip.addSubview(chevronView)
        chip.addSubview(headerButton)
        chip.addSubview(contentContainer)
    }

    func configure(
        markdown: MarkdownTextView.PreprocessedContent,
        theme: MarkdownTheme,
        renderToken: String,
        isExpanded: Bool,
        isStreaming _: Bool,
        onToggle: @escaping () -> Void
    ) {
        if markdownView.theme != theme {
            markdownView.theme = theme
        }
        let wasExpanded = self.isExpanded
        self.onToggle = onToggle
        self.isExpanded = isExpanded
        if renderedToken != renderToken {
            renderedToken = renderToken
            markdownView.setMarkdown(markdown)
        }
        let targetTransform = isExpanded ? CGAffineTransform(rotationAngle: .pi) : .identity
        if wasExpanded != isExpanded, superview != nil {
            // Animate chevron + chip width together when toggling.
            layoutIfNeeded()
            if isExpanded {
                contentContainer.isHidden = false
                contentContainer.alpha = 0
            }
            UIView.animate(
                withDuration: 0.2,
                delay: 0,
                options: [.curveEaseInOut, .beginFromCurrentState]
            ) {
                self.chevronView.transform = targetTransform
                self.setNeedsLayout()
                self.layoutIfNeeded()
            } completion: { _ in
                if isExpanded {
                    self.contentContainer.isHidden = false
                    UIView.animate(
                        withDuration: 0.12,
                        delay: 0,
                        options: [.curveEaseOut, .beginFromCurrentState]
                    ) {
                        self.contentContainer.alpha = 1
                    }
                } else {
                    self.contentContainer.alpha = 1
                    self.contentContainer.isHidden = true
                }
            }
        } else {
            contentContainer.isHidden = !isExpanded
            contentContainer.alpha = 1
            chevronView.transform = targetTransform
            setNeedsLayout()
        }
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        onToggle = nil
    }

    override func layoutSubviews() {
        super.layoutSubviews()

        let iconSize: CGFloat = 14
        let chevronSize: CGFloat = 10
        let leadingPadding: CGFloat = 14
        let headerHeight = Self.collapsedHeight
        let collapsedChipWidth = Self.collapsedWidth(
            titleText: titleLabel.text ?? "",
            titleFont: titleLabel.font,
            iconSize: iconSize,
            chevronSize: chevronSize,
            leadingPadding: leadingPadding
        )
        let chipWidth = isExpanded
            ? rowContainer.bounds.width
            : min(rowContainer.bounds.width, collapsedChipWidth)
        chip.frame = CGRect(x: 0, y: 0, width: chipWidth, height: rowContainer.bounds.height)

        iconView.frame = CGRect(x: leadingPadding, y: (headerHeight - iconSize) / 2, width: iconSize, height: iconSize)
        let titleX = iconView.frame.maxX + 6
        let titleHeight = ceil(titleLabel.font.lineHeight)
        let maxTitleWidth = max(0, chip.bounds.width - titleX - leadingPadding - chevronSize - 4)
        let measuredTitleWidth = ceil(titleLabel.sizeThatFits(CGSize(width: maxTitleWidth, height: headerHeight)).width)
        let titleWidth = min(maxTitleWidth, measuredTitleWidth)
        titleLabel.frame = CGRect(
            x: titleX,
            y: (headerHeight - titleHeight) / 2,
            width: titleWidth,
            height: titleHeight
        )
        let chevronX = min(chip.bounds.width - leadingPadding - chevronSize, titleLabel.frame.maxX + 4)
        chevronView.frame = CGRect(
            x: chevronX,
            y: (headerHeight - chevronSize) / 2,
            width: chevronSize,
            height: chevronSize
        )
        headerButton.frame = CGRect(x: 0, y: 0, width: chip.bounds.width, height: headerHeight)

        if isExpanded {
            contentContainer.isHidden = false
            contentContainer.frame = CGRect(
                x: Self.horizontalPadding,
                y: headerHeight + Self.contentSpacing,
                width: max(0, chip.bounds.width - (Self.horizontalPadding * 2)),
                height: max(0, chip.bounds.height - headerHeight - Self.contentSpacing - Self.bottomPadding)
            )
            markdownView.frame = contentContainer.bounds
            let scrollView = superListView
            if boundScrollView !== scrollView {
                boundScrollView = scrollView
                markdownView.bindContentOffset(from: scrollView)
            }
        } else {
            contentContainer.isHidden = true
            contentContainer.frame = .zero
            markdownView.frame = .zero
        }
    }

    private static func collapsedWidth(
        titleText: String,
        titleFont: UIFont,
        iconSize: CGFloat,
        chevronSize: CGFloat,
        leadingPadding: CGFloat
    ) -> CGFloat {
        let titleWidth = ceil((titleText as NSString).size(withAttributes: [.font: titleFont]).width)
        return ceil(leadingPadding + iconSize + 6 + titleWidth + 4 + chevronSize + leadingPadding)
    }

    @objc private func handleHeaderTap() {
        onToggle?()
    }
}

private final class SystemRowView: BaseRowView {
    var text: String = "" {
        didSet {
            label.text = text
            setNeedsLayout()
        }
    }

    private let isError: Bool
    private let card = UIView()
    private let iconView = UIImageView()
    private let label = UILabel()

    init(isError: Bool) {
        self.isError = isError
        super.init(frame: .zero)

        card.layer.cornerCurve = .continuous
        card.backgroundColor = isError ? UIColor.systemRed.withAlphaComponent(0.10) : UIColor.systemGray5

        iconView.image = UIImage(systemName: isError ? "exclamationmark.triangle.fill" : "info.circle")
        iconView.tintColor = isError ? .systemRed : .secondaryLabel
        iconView.contentMode = .scaleAspectFit

        label.numberOfLines = 1
        label.font = .preferredFont(forTextStyle: .footnote)
        label.textColor = isError ? .systemRed : .secondaryLabel

        rowContainer.addSubview(card)
        card.addSubview(iconView)
        card.addSubview(label)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let maxWidth = max(0, rowContainer.bounds.width - 16)
        let iconSize: CGFloat = 14
        let labelSize = label.sizeThatFits(CGSize(width: maxWidth - 6 - iconSize - 24, height: .greatestFiniteMagnitude))
        let cardWidth = min(maxWidth, ceil(labelSize.width) + 12 + 6 + iconSize + 12)
        let cardHeight = max(26, ceil(labelSize.height) + 12)
        card.frame = CGRect(
            x: (rowContainer.bounds.width - cardWidth) / 2,
            y: max(0, (rowContainer.bounds.height - cardHeight) / 2),
            width: cardWidth,
            height: cardHeight
        )
        card.layer.cornerRadius = cardHeight / 2

        iconView.frame = CGRect(x: 12, y: (cardHeight - iconSize) / 2, width: iconSize, height: iconSize)
        let labelX = iconView.frame.maxX + 6
        label.frame = CGRect(x: labelX, y: (cardHeight - ceil(labelSize.height)) / 2, width: cardWidth - labelX - 12, height: ceil(labelSize.height))
    }
}

private final class StreamingIndicatorRowView: BaseRowView {
    var text: String = "Thinking…" {
        didSet {
            label.text = text
        }
    }

    private let card = UIView()
    private let label = UILabel()
    private let spinner = UIActivityIndicatorView(style: .medium)

    override init(frame: CGRect) {
        super.init(frame: frame)
        card.layer.cornerRadius = 18
        card.layer.cornerCurve = .continuous
        card.backgroundColor = UIColor.systemGray6

        label.font = .preferredFont(forTextStyle: .footnote)
        label.textColor = .secondaryLabel

        spinner.startAnimating()

        rowContainer.addSubview(card)
        card.addSubview(spinner)
        card.addSubview(label)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let labelSize = label.sizeThatFits(CGSize(width: rowContainer.bounds.width - 44, height: .greatestFiniteMagnitude))
        let cardHeight: CGFloat = 32
        let cardWidth = min(rowContainer.bounds.width, 10 + 16 + 6 + ceil(labelSize.width) + 10)
        card.frame = CGRect(x: 0, y: 0, width: cardWidth, height: cardHeight)
        spinner.frame = CGRect(x: 10, y: (card.bounds.height - 16) / 2, width: 16, height: 16)
        label.frame = CGRect(
            x: spinner.frame.maxX + 6,
            y: (card.bounds.height - ceil(labelSize.height)) / 2,
            width: card.bounds.width - spinner.frame.maxX - 16,
            height: ceil(labelSize.height)
        )
    }
}

private final class ToolCallRowView: BaseRowView {
    struct Payload {
        let title: String
        let status: String?
        let kind: String?
        let output: String?
        let acpPermissionRequestId: ACP.ID?
        let permissionRequestId: JSONRPCID?
        let permissionOptions: [ACPPermissionOption]
        let approvalRequestId: JSONRPCID?
        let approvalReason: String?
        let approvalCommand: String?
        let approvalCwd: String?
        let isStreaming: Bool

        init(entry: ChatEntry) {
            let tool = entry.segment?.toolCall
            self.title = tool?.title ?? entry.text
            self.status = tool?.status
            self.kind = tool?.kind
            self.output = tool?.output
            self.acpPermissionRequestId = tool?.acpPermissionRequestId
            self.permissionRequestId = tool?.permissionRequestId
            self.permissionOptions = tool?.permissionOptions ?? []
            self.approvalRequestId = tool?.approvalRequestId
            self.approvalReason = tool?.approvalReason
            self.approvalCommand = tool?.approvalCommand
            self.approvalCwd = tool?.approvalCwd
            self.isStreaming = entry.isStreaming
        }
    }

    private var onACPPermission: ((ACP.ID, String) -> Void)?
    private var onJSONRPCPermission: ((JSONRPCID, String) -> Void)?
    private var onApprove: ((JSONRPCID, Bool?) -> Void)?
    private var onDecline: ((JSONRPCID) -> Void)?

    private var payload: Payload?

    private let card = UIView()
    private let titleLabel = UILabel()
    private let subtitleLabel = UILabel()
    private let resultIcon = UIImageView()
    private let resultLabel = UILabel()
    private let outputLabel = UILabel()
    private let leadingIcon = UIImageView()
    private let trailingStatusIcon = UIImageView()
    private let trailingStatusSpinner = UIActivityIndicatorView(style: .medium)
    private let buttonStack = UIStackView()

    override init(frame: CGRect) {
        super.init(frame: frame)

        card.layer.cornerRadius = 16
        card.layer.cornerCurve = .continuous
        card.backgroundColor = UIColor.systemOrange.withAlphaComponent(0.10)
        card.layer.borderWidth = 0

        titleLabel.numberOfLines = 0
        titleLabel.font = .preferredFont(forTextStyle: .footnote).withWeight(.medium)
        titleLabel.textColor = .label

        subtitleLabel.numberOfLines = 0
        subtitleLabel.font = .preferredFont(forTextStyle: .caption2)
        subtitleLabel.textColor = .secondaryLabel

        resultIcon.image = UIImage(systemName: "checkmark.circle")
        resultIcon.tintColor = .systemGreen
        resultIcon.contentMode = .scaleAspectFit

        resultLabel.text = "Result"
        resultLabel.font = .preferredFont(forTextStyle: .footnote).withWeight(.medium)
        resultLabel.textColor = .systemGreen

        outputLabel.numberOfLines = 5
        outputLabel.font = .preferredFont(forTextStyle: .caption1)
        outputLabel.textColor = .secondaryLabel

        leadingIcon.tintColor = .systemOrange
        trailingStatusIcon.tintColor = .secondaryLabel
        trailingStatusSpinner.hidesWhenStopped = true

        buttonStack.axis = .vertical
        buttonStack.spacing = 6
        buttonStack.alignment = .leading

        rowContainer.addSubview(card)
        card.addSubview(leadingIcon)
        card.addSubview(trailingStatusIcon)
        card.addSubview(trailingStatusSpinner)
        card.addSubview(titleLabel)
        card.addSubview(subtitleLabel)
        card.addSubview(resultIcon)
        card.addSubview(resultLabel)
        card.addSubview(outputLabel)
        card.addSubview(buttonStack)
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        payload = nil
        clearButtons()
    }

    func configure(
        payload: Payload,
        onACPPermission: @escaping (ACP.ID, String) -> Void,
        onJSONRPCPermission: @escaping (JSONRPCID, String) -> Void,
        onApprove: @escaping (JSONRPCID, Bool?) -> Void,
        onDecline: @escaping (JSONRPCID) -> Void
    ) {
        self.payload = payload
        self.onACPPermission = onACPPermission
        self.onJSONRPCPermission = onJSONRPCPermission
        self.onApprove = onApprove
        self.onDecline = onDecline

        titleLabel.text = payload.title

        let normalizedStatus = payload.status?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let isAwaitingPermission = normalizedStatus == "awaiting_permission"
            && (!payload.permissionOptions.isEmpty || payload.approvalRequestId != nil)
        leadingIcon.image = UIImage(systemName: "hammer")
        leadingIcon.tintColor = .systemOrange

        trailingStatusIcon.isHidden = true
        trailingStatusSpinner.stopAnimating()
        trailingStatusIcon.frame = .zero
        trailingStatusSpinner.frame = .zero
        if isAwaitingPermission {
            trailingStatusIcon.isHidden = false
            trailingStatusIcon.image = UIImage(systemName: "exclamationmark.shield.fill")
            trailingStatusIcon.tintColor = .systemOrange
        }

        card.backgroundColor = UIColor.systemOrange.withAlphaComponent(0.10)
        card.layer.borderColor = UIColor.clear.cgColor
        card.layer.borderWidth = 0

        var details: [String] = []
        if let reason = payload.approvalReason, !reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            details.append("Reason: \(reason)")
        }
        if let command = payload.approvalCommand, !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            details.append("Command: \(command)")
        }
        if let cwd = payload.approvalCwd, !cwd.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            details.append("CWD: \(cwd)")
        }
        subtitleLabel.text = details.joined(separator: "\n")

        if let output = payload.output?.trimmingCharacters(in: .whitespacesAndNewlines), !output.isEmpty {
            outputLabel.text = output.truncatedToolOutput(maxLines: 6, maxChars: 1200)
            outputLabel.isHidden = false
            resultIcon.isHidden = false
            resultLabel.isHidden = false
        } else {
            outputLabel.text = nil
            outputLabel.isHidden = true
            resultIcon.isHidden = true
            resultLabel.isHidden = true
        }

        rebuildButtons(payload: payload)
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        card.frame = rowContainer.bounds

        let availableWidth = max(0, card.bounds.width - 20)
        guard availableWidth > 0 else {
            leadingIcon.frame = .zero
            trailingStatusIcon.frame = .zero
            trailingStatusSpinner.frame = .zero
            titleLabel.frame = .zero
            subtitleLabel.frame = .zero
            resultIcon.frame = .zero
            resultLabel.frame = .zero
            outputLabel.frame = .zero
            buttonStack.frame = .zero
            return
        }

        let statusSize: CGFloat = 16
        let iconX: CGFloat = 10
        let trailingX = card.bounds.width - 10 - statusSize
        let hasTrailingStatus = !trailingStatusIcon.isHidden || trailingStatusSpinner.isAnimating

        let titleX = iconX + statusSize + 8
        let trailingReservedWidth: CGFloat = hasTrailingStatus ? (statusSize + 8) : 0
        let titleWidth = max(1, card.bounds.width - titleX - 10 - trailingReservedWidth)
        let measuredTitleHeight = ceil(titleLabel.sizeThatFits(CGSize(width: titleWidth, height: .greatestFiniteMagnitude)).height)
        let titleHeight = max(measuredTitleHeight, ceil(titleLabel.font.lineHeight))
        let subtitleText = subtitleLabel.text ?? ""
        let hasSubtitle = !subtitleText.isEmpty
        let hasOutput = !outputLabel.isHidden
        let hasButtons = !buttonStack.arrangedSubviews.isEmpty
        let hasSupplementaryContent = hasSubtitle || hasOutput || hasButtons
        let titleY = hasSupplementaryContent
            ? CGFloat(8)
            : max(8, floor((card.bounds.height - titleHeight) / 2))
        titleLabel.frame = CGRect(x: titleX, y: titleY, width: titleWidth, height: titleHeight)

        let statusY = titleLabel.frame.minY + max(0, (titleLabel.frame.height - statusSize) / 2)
        leadingIcon.frame = CGRect(x: iconX, y: statusY, width: statusSize, height: statusSize)
        if trailingStatusSpinner.isAnimating {
            trailingStatusSpinner.frame = CGRect(x: trailingX, y: statusY, width: statusSize, height: statusSize)
            trailingStatusIcon.frame = .zero
        } else if trailingStatusIcon.isHidden {
            trailingStatusIcon.frame = .zero
            trailingStatusSpinner.frame = .zero
        } else {
            trailingStatusIcon.frame = CGRect(x: trailingX, y: statusY, width: statusSize, height: statusSize)
            trailingStatusSpinner.frame = .zero
        }

        var currentY = titleLabel.frame.maxY + 6

        if hasSubtitle {
            let subtitleHeight = ceil(subtitleLabel.sizeThatFits(CGSize(width: availableWidth, height: .greatestFiniteMagnitude)).height)
            subtitleLabel.frame = CGRect(x: 10, y: currentY, width: availableWidth, height: subtitleHeight)
            currentY = subtitleLabel.frame.maxY + 6
        } else {
            subtitleLabel.frame = .zero
        }

        if !outputLabel.isHidden {
            resultIcon.frame = CGRect(x: 10, y: currentY + 1, width: 14, height: 14)
            let resultTextSize = resultLabel.sizeThatFits(CGSize(width: 80, height: CGFloat.greatestFiniteMagnitude))
            resultLabel.frame = CGRect(
                x: resultIcon.frame.maxX + 6,
                y: currentY - 1,
                width: ceil(resultTextSize.width),
                height: max(16, ceil(resultTextSize.height))
            )
            currentY = resultIcon.frame.maxY + 6

            let outputHeight = ceil(outputLabel.sizeThatFits(CGSize(width: availableWidth, height: .greatestFiniteMagnitude)).height)
            outputLabel.frame = CGRect(x: 10, y: currentY, width: availableWidth, height: outputHeight)
            currentY = outputLabel.frame.maxY + 8
        } else {
            resultIcon.frame = .zero
            resultLabel.frame = .zero
            outputLabel.frame = .zero
        }

        let buttonSize = buttonStack.systemLayoutSizeFitting(
            CGSize(width: availableWidth, height: .greatestFiniteMagnitude),
            withHorizontalFittingPriority: .required,
            verticalFittingPriority: .fittingSizeLevel
        )
        if buttonSize.height > 0 {
            buttonStack.frame = CGRect(x: 10, y: currentY, width: availableWidth, height: ceil(buttonSize.height))
        } else {
            buttonStack.frame = .zero
        }
    }

    static func estimatedHeight(for payload: Payload, width: CGFloat) -> CGFloat {
        let contentWidth = max(0, width - 20)
        let titleFont = UIFont.preferredFont(forTextStyle: .footnote).bold()
        let titleHeight = (payload.title as NSString).boundingRect(
            with: CGSize(width: contentWidth - 24, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: titleFont],
            context: nil
        ).height

        var total = ceil(titleHeight) + 18

        var details: [String] = []
        if let reason = payload.approvalReason, !reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            details.append("Reason: \(reason)")
        }
        if let command = payload.approvalCommand, !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            details.append("Command: \(command)")
        }
        if let cwd = payload.approvalCwd, !cwd.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            details.append("CWD: \(cwd)")
        }
        if !details.isEmpty {
            let text = details.joined(separator: "\n")
            let subtitleHeight = (text as NSString).boundingRect(
                with: CGSize(width: contentWidth, height: .greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin, .usesFontLeading],
                attributes: [.font: UIFont.preferredFont(forTextStyle: .caption2)],
                context: nil
            ).height
            total += ceil(subtitleHeight) + 6
        }

        if let output = payload.output?.trimmingCharacters(in: .whitespacesAndNewlines), !output.isEmpty {
            let displayOutput = output.truncatedToolOutput(maxLines: 6, maxChars: 1200)
            total += 20
            let outputHeight = (displayOutput as NSString).boundingRect(
                with: CGSize(width: contentWidth, height: .greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin, .usesFontLeading],
                attributes: [.font: UIFont.preferredFont(forTextStyle: .caption1)],
                context: nil
            ).height
            total += ceil(outputHeight) + 8
        }

        if payload.approvalRequestId != nil {
            total += 72
        }

        if !payload.permissionOptions.isEmpty {
            total += CGFloat(payload.permissionOptions.count) * 34
        }

        return max(total + 8, 48)
    }

    private func rebuildButtons(payload: Payload) {
        clearButtons()

        if let approvalRequestId = payload.approvalRequestId {
            let approve = makeButton(
                title: "Approve",
                tint: .systemGreen,
                backgroundColor: UIColor.systemGreen.withAlphaComponent(0.15),
                textColor: .systemGreen,
                symbolName: "checkmark.circle"
            ) { [weak self] in
                self?.onApprove?(approvalRequestId, nil)
            }
            let decline = makeButton(
                title: "Decline",
                tint: .systemRed,
                backgroundColor: UIColor.systemRed.withAlphaComponent(0.15),
                textColor: .systemRed,
                symbolName: "xmark.circle"
            ) { [weak self] in
                self?.onDecline?(approvalRequestId)
            }
            let approvalRow = UIStackView(arrangedSubviews: [approve, decline])
            approvalRow.axis = .horizontal
            approvalRow.spacing = 8
            approvalRow.alignment = .leading
            buttonStack.addArrangedSubview(approvalRow)
        }

        if !payload.permissionOptions.isEmpty {
            let optionsRow = UIStackView()
            optionsRow.axis = .horizontal
            optionsRow.spacing = 8
            optionsRow.alignment = .leading
            for option in payload.permissionOptions {
                let tint = colorForPermissionKind(option.kind)
                let button = makeButton(
                    title: option.name.truncatedLabel(maxChars: 24),
                    tint: tint,
                    backgroundColor: tint.withAlphaComponent(0.15),
                    textColor: foregroundColorForPermissionKind(option.kind),
                    symbolName: iconForPermissionKind(option.kind)
                ) { [weak self] in
                    guard let self else { return }
                    if let requestId = payload.acpPermissionRequestId {
                        self.onACPPermission?(requestId, option.optionId)
                    } else if let requestId = payload.permissionRequestId {
                        self.onJSONRPCPermission?(requestId, option.optionId)
                    }
                }
                optionsRow.addArrangedSubview(button)
            }
            buttonStack.addArrangedSubview(optionsRow)
        }
    }

    private func clearButtons() {
        for view in buttonStack.arrangedSubviews {
            buttonStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
    }

    private func makeButton(
        title: String,
        tint: UIColor,
        backgroundColor: UIColor,
        textColor: UIColor,
        symbolName: String? = nil,
        action: @escaping () -> Void
    ) -> UIButton {
        let button = ActionButton(type: .system)
        button.action = action

        var config = UIButton.Configuration.filled()
        config.title = title
        config.image = symbolName.flatMap { UIImage(systemName: $0) }
        config.imagePadding = symbolName == nil ? 0 : 4
        config.baseForegroundColor = tint
        config.baseBackgroundColor = backgroundColor
        config.contentInsets = NSDirectionalEdgeInsets(top: 6, leading: 10, bottom: 6, trailing: 10)
        config.background.cornerRadius = 8
        config.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { incoming in
            var outgoing = incoming
            outgoing.font = .preferredFont(forTextStyle: .caption1).withWeight(.medium)
            outgoing.foregroundColor = textColor
            return outgoing
        }
        button.configuration = config
        button.semanticContentAttribute = .forceLeftToRight

        return button
    }

    private func colorForPermissionKind(_ kind: ACPPermissionOptionKind) -> UIColor {
        switch kind {
        case .allowOnce, .allowAlways:
            return .systemGreen
        case .rejectOnce, .rejectAlways:
            return .systemRed
        case .unknown:
            return .systemGray
        }
    }

    private func foregroundColorForPermissionKind(_ kind: ACPPermissionOptionKind) -> UIColor {
        switch kind {
        case .allowOnce, .allowAlways:
            return .systemGreen
        case .rejectOnce, .rejectAlways:
            return .systemRed
        case .unknown:
            return .label
        }
    }

    private func iconForPermissionKind(_ kind: ACPPermissionOptionKind) -> String {
        switch kind {
        case .allowOnce, .allowAlways:
            return "checkmark.circle"
        case .rejectOnce, .rejectAlways:
            return "xmark.circle"
        case .unknown:
            return "questionmark.circle"
        }
    }

    private func iconForToolKind(_ kind: String?) -> String {
        switch kind?.lowercased() {
        case "read": return "doc.text.magnifyingglass"
        case "edit": return "pencil"
        case "delete": return "trash"
        case "move": return "arrow.right.doc.on.clipboard"
        case "search": return "magnifyingglass"
        case "execute": return "terminal"
        case "think": return "brain"
        case "fetch": return "arrow.down.circle"
        default: return "wrench.and.screwdriver"
        }
    }

    private func colorForToolKind(_ kind: String?) -> UIColor {
        switch kind?.lowercased() {
        case "read": return .systemBlue
        case "edit": return .systemOrange
        case "delete": return .systemRed
        case "execute": return .systemPurple
        case "search": return .systemGreen
        case "think": return .systemIndigo
        case "fetch": return .systemCyan
        default: return .systemOrange
        }
    }
}

private final class FileChangesRowView: BaseRowView {
    private var onUndo: (() -> Void)?
    private var onReview: (([FileChangeSummaryItem]) -> Void)?
    private var items: [FileChangeSummaryItem] = []
    private var itemRows: [FileChangePreviewRowView] = []

    private let card = UIView()
    private let summaryLabel = UILabel()
    private let undoButton = ActionButton(type: .system)
    private let reviewButton = ActionButton(type: .system)

    override init(frame: CGRect) {
        super.init(frame: frame)

        card.layer.cornerRadius = 14
        card.layer.cornerCurve = .continuous
        card.backgroundColor = UIColor.systemGray5

        summaryLabel.font = .preferredFont(forTextStyle: .footnote).withWeight(.semibold)
        summaryLabel.textColor = .label
        summaryLabel.numberOfLines = 1

        var undoConfig = UIButton.Configuration.bordered()
        undoConfig.title = "Undo"
        undoConfig.baseForegroundColor = .systemBlue
        undoConfig.cornerStyle = .capsule
        undoConfig.contentInsets = NSDirectionalEdgeInsets(top: 6, leading: 14, bottom: 6, trailing: 14)
        undoConfig.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { incoming in
            var outgoing = incoming
            outgoing.font = .preferredFont(forTextStyle: .caption1).withWeight(.semibold)
            return outgoing
        }
        undoButton.configuration = undoConfig

        var reviewConfig = UIButton.Configuration.borderedProminent()
        reviewConfig.title = "Review"
        reviewConfig.baseForegroundColor = .white
        reviewConfig.baseBackgroundColor = .systemBlue
        reviewConfig.cornerStyle = .capsule
        reviewConfig.contentInsets = NSDirectionalEdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16)
        reviewConfig.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { incoming in
            var outgoing = incoming
            outgoing.font = .preferredFont(forTextStyle: .caption1).withWeight(.semibold)
            return outgoing
        }
        reviewButton.configuration = reviewConfig

        rowContainer.addSubview(card)
        card.addSubview(summaryLabel)
        card.addSubview(undoButton)
        card.addSubview(reviewButton)

        undoButton.action = { [weak self] in
            self?.onUndo?()
        }
        reviewButton.action = { [weak self] in
            guard let self else { return }
            self.onReview?(self.items)
        }
    }

    func configure(items: [FileChangeSummaryItem], onUndo: @escaping () -> Void, onReview: @escaping ([FileChangeSummaryItem]) -> Void) {
        self.items = deduplicate(items)
        self.onUndo = onUndo
        self.onReview = onReview

        let count = self.items.count
        summaryLabel.text = count == 1 ? "1 file changed" : "\(count) files changed"
        rebuildItemRows()
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        card.frame = rowContainer.bounds

        let horizontalPadding: CGFloat = 12
        let topPadding: CGFloat = 12
        let buttonHeight: CGFloat = 32
        let width = card.bounds.width

        let reviewSize = reviewButton.sizeThatFits(CGSize(width: CGFloat.greatestFiniteMagnitude, height: buttonHeight))
        let reviewWidth = max(84, ceil(reviewSize.width))
        reviewButton.frame = CGRect(
            x: width - horizontalPadding - reviewWidth,
            y: topPadding,
            width: reviewWidth,
            height: buttonHeight
        )

        let undoSize = undoButton.sizeThatFits(CGSize(width: CGFloat.greatestFiniteMagnitude, height: buttonHeight))
        let undoWidth = max(72, ceil(undoSize.width))
        undoButton.frame = CGRect(
            x: reviewButton.frame.minX - 10 - undoWidth,
            y: topPadding,
            width: undoWidth,
            height: buttonHeight
        )

        let summaryAvailableWidth = max(0, undoButton.frame.minX - horizontalPadding - 10)
        let summarySize = summaryLabel.sizeThatFits(CGSize(width: summaryAvailableWidth, height: buttonHeight))
        summaryLabel.frame = CGRect(
            x: horizontalPadding,
            y: topPadding + floor((buttonHeight - ceil(summarySize.height)) / 2),
            width: summaryAvailableWidth,
            height: ceil(summarySize.height)
        )

        var currentY = max(summaryLabel.frame.maxY, reviewButton.frame.maxY) + 10
        let rowWidth = max(0, width - (horizontalPadding * 2))
        for (index, row) in itemRows.enumerated() {
            let rowHeight = ceil(row.sizeThatFits(CGSize(width: rowWidth, height: .greatestFiniteMagnitude)).height)
            row.frame = CGRect(x: horizontalPadding, y: currentY, width: rowWidth, height: rowHeight)
            currentY += rowHeight
            if index < itemRows.count - 1 {
                currentY += 8
            }
        }
    }

    static func estimatedHeight(for items: [FileChangeSummaryItem], width: CGFloat) -> CGFloat {
        let deduped = deduplicate(items)
        let horizontalPadding: CGFloat = 12
        let iconSize = ceil(UIFont.preferredFont(forTextStyle: .footnote).lineHeight)
        let textLeadingSpacing: CGFloat = 8
        let textWidth = max(0, width - (horizontalPadding * 2) - iconSize - textLeadingSpacing)
        let pathFont = UIFont.preferredFont(forTextStyle: .footnote)
        let statusFont = UIFont.preferredFont(forTextStyle: .caption2)

        var rowsHeight: CGFloat = 0
        for item in deduped {
            let pathHeight = (item.path as NSString).boundingRect(
                with: CGSize(width: textWidth, height: .greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin, .usesFontLeading],
                attributes: [.font: pathFont],
                context: nil
            ).height
            var textBlockHeight = ceil(pathHeight)
            if let statusText = statusText(for: item), !statusText.isEmpty {
                let statusHeight = (statusText as NSString).boundingRect(
                    with: CGSize(width: textWidth, height: .greatestFiniteMagnitude),
                    options: [.usesLineFragmentOrigin, .usesFontLeading],
                    attributes: [.font: statusFont],
                    context: nil
                ).height
                textBlockHeight += 2 + ceil(statusHeight)
            }
            let rowHeight = max(iconSize, textBlockHeight)
            rowsHeight += rowHeight
        }

        if deduped.count > 1 {
            rowsHeight += CGFloat(deduped.count - 1) * 8
        }

        let headerHeight: CGFloat = 12 + 32
        let contentSpacing: CGFloat = deduped.isEmpty ? 0 : 10
        let bottomPadding: CGFloat = 12
        return max(headerHeight + contentSpacing + rowsHeight + bottomPadding, 68)
    }

    private static func deduplicate(_ items: [FileChangeSummaryItem]) -> [FileChangeSummaryItem] {
        var chosen: [String: FileChangeSummaryItem] = [:]
        var order: [String] = []

        for item in items {
            let key = normalizedPathKey(item.path)
            if let existing = chosen[key] {
                chosen[key] = preferredItem(existing, item)
            } else {
                order.append(key)
                chosen[key] = item
            }
        }

        return order.compactMap { chosen[$0] }
    }

    private func deduplicate(_ items: [FileChangeSummaryItem]) -> [FileChangeSummaryItem] {
        Self.deduplicate(items)
    }

    private static func normalizedPathKey(_ path: String) -> String {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "unknown" }
        let separators = CharacterSet(charactersIn: "/\\")
        let parts = trimmed.components(separatedBy: separators).filter { !$0.isEmpty }
        return (parts.last ?? trimmed).lowercased()
    }

    private static func preferredItem(_ existing: FileChangeSummaryItem, _ candidate: FileChangeSummaryItem) -> FileChangeSummaryItem {
        let existingPath = existing.path.trimmingCharacters(in: .whitespacesAndNewlines)
        let candidatePath = candidate.path.trimmingCharacters(in: .whitespacesAndNewlines)
        let existingHasSeparator = existingPath.contains("/") || existingPath.contains("\\")
        let candidateHasSeparator = candidatePath.contains("/") || candidatePath.contains("\\")

        if existingHasSeparator != candidateHasSeparator {
            return existingHasSeparator ? existing : candidate
        }

        let existingVerb = existing.verb?.lowercased() ?? ""
        let candidateVerb = candidate.verb?.lowercased() ?? ""
        let existingStatus = existing.status?.lowercased() ?? ""
        let candidateStatus = candidate.status?.lowercased() ?? ""
        let existingIsDiff = existingVerb == "diff" || existingStatus == "diff"
        let candidateIsDiff = candidateVerb == "diff" || candidateStatus == "diff"

        if existingIsDiff != candidateIsDiff {
            return existingIsDiff ? candidate : existing
        }

        if existingPath.count != candidatePath.count {
            return existingPath.count >= candidatePath.count ? existing : candidate
        }

        return existing
    }

    private static func statusText(for item: FileChangeSummaryItem) -> String? {
        if let verb = item.verb?.trimmingCharacters(in: .whitespacesAndNewlines), !verb.isEmpty {
            return verb.capitalized
        }
        if let status = item.status?.trimmingCharacters(in: .whitespacesAndNewlines), !status.isEmpty {
            return status.replacingOccurrences(of: "_", with: " ").capitalized
        }
        return nil
    }

    private func rebuildItemRows() {
        if itemRows.count < items.count {
            for _ in itemRows.count..<items.count {
                let row = FileChangePreviewRowView()
                card.addSubview(row)
                itemRows.append(row)
            }
        }
        if itemRows.count > items.count {
            for row in itemRows[items.count...] {
                row.removeFromSuperview()
            }
            itemRows.removeSubrange(items.count...)
        }
        for (index, item) in items.enumerated() {
            itemRows[index].configure(path: item.path, status: Self.statusText(for: item))
        }
    }
}

private final class FileChangePreviewRowView: UIView {
    private let iconView = UIImageView()
    private let pathLabel = UILabel()
    private let statusLabel = UILabel()

    private var pathText: String = ""
    private var statusText: String?

    override init(frame: CGRect) {
        super.init(frame: frame)
        iconView.image = UIImage(
            systemName: "doc.text",
            withConfiguration: UIImage.SymbolConfiguration(textStyle: .footnote)
        )
        iconView.tintColor = .secondaryLabel
        iconView.contentMode = .scaleAspectFit

        pathLabel.font = .preferredFont(forTextStyle: .footnote)
        pathLabel.textColor = .label
        pathLabel.numberOfLines = 0

        statusLabel.font = .preferredFont(forTextStyle: .caption2)
        statusLabel.textColor = .secondaryLabel
        statusLabel.numberOfLines = 0

        addSubview(iconView)
        addSubview(pathLabel)
        addSubview(statusLabel)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(path: String, status: String?) {
        pathText = path
        statusText = status
        pathLabel.text = path
        statusLabel.text = status
        statusLabel.isHidden = status == nil || status?.isEmpty == true
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let iconSize = max(1, ceil(iconView.sizeThatFits(.zero).width))
        let textX = iconSize + 8
        let textWidth = max(0, bounds.width - textX)
        let pathSize = pathLabel.sizeThatFits(CGSize(width: textWidth, height: .greatestFiniteMagnitude))
        let pathHeight = ceil(pathSize.height)
        var textBlockHeight = pathHeight
        var statusHeight: CGFloat = 0

        if !statusLabel.isHidden {
            let statusSize = statusLabel.sizeThatFits(CGSize(width: textWidth, height: .greatestFiniteMagnitude))
            statusHeight = ceil(statusSize.height)
            textBlockHeight += 2 + statusHeight
        }

        let rowHeight = max(bounds.height, max(iconSize, textBlockHeight))
        let textBlockY = floor((rowHeight - textBlockHeight) / 2)
        let iconY = floor((rowHeight - iconSize) / 2)

        iconView.frame = CGRect(
            x: 0,
            y: max(0, iconY),
            width: iconSize,
            height: iconSize
        )
        pathLabel.frame = CGRect(
            x: textX,
            y: max(0, textBlockY),
            width: textWidth,
            height: pathHeight
        )

        if statusLabel.isHidden {
            statusLabel.frame = .zero
        } else {
            statusLabel.frame = CGRect(
                x: textX,
                y: pathLabel.frame.maxY + 2,
                width: textWidth,
                height: statusHeight
            )
        }
    }

    override func sizeThatFits(_ size: CGSize) -> CGSize {
        let iconSize = max(1, ceil(iconView.sizeThatFits(.zero).width))
        let textWidth = max(0, size.width - iconSize - 8)
        let pathHeight = ceil(pathLabel.sizeThatFits(CGSize(width: textWidth, height: .greatestFiniteMagnitude)).height)
        var textBlockHeight = pathHeight
        if let statusText, !statusText.isEmpty {
            let statusHeight = ceil((statusText as NSString).boundingRect(
                with: CGSize(width: textWidth, height: .greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin, .usesFontLeading],
                attributes: [.font: statusLabel.font as Any],
                context: nil
            ).height)
            textBlockHeight = pathHeight + 2 + statusHeight
        }
        return CGSize(width: size.width, height: max(textBlockHeight, iconSize))
    }
}

private final class ActionButton: UIButton {
    var action: (() -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        addTarget(self, action: #selector(handleTap), for: .touchUpInside)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    @objc private func handleTap() {
        action?()
    }
}

private extension UIFont {
    func bold() -> UIFont {
        guard let descriptor = fontDescriptor.withSymbolicTraits(.traitBold) else {
            return self
        }
        return UIFont(descriptor: descriptor, size: pointSize)
    }

    func withWeight(_ weight: UIFont.Weight) -> UIFont {
        let descriptor = fontDescriptor.addingAttributes([
            .traits: [UIFontDescriptor.TraitKey.weight: weight]
        ])
        return UIFont(descriptor: descriptor, size: pointSize)
    }
}
#endif
