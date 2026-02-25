import UIKit
import ACP
import ACPClient

final class ToolCallRowView: BaseRowView {
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
