import AppKit
import Foundation

@MainActor
class HUDManager {
    static let shared = HUDManager()

    private var window: NSWindow?
    private var fadeTimer: Timer?

    // MARK: - Public entry points

    func show(workspace: Workspace) {
        let dotSize: CGFloat = 40
        let horizontalPadding: CGFloat = 28
        let verticalPadding: CGFloat = 24
        let stackSpacing: CGFloat = 20
        let minPanelWidth: CGFloat = 220
        let minPanelHeight: CGFloat = 200

        let labelFont = NSFont.systemFont(ofSize: 22, weight: .bold)
        let screenWidth = NSScreen.main?.visibleFrame.width ?? 1200
        let maxPanelWidth = min(420, screenWidth * 0.45)
        let maxLabelWidth = max(160, maxPanelWidth - (horizontalPadding * 2))

        let textRect = (workspace.name as NSString).boundingRect(
            with: NSSize(width: maxLabelWidth, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: labelFont]
        )
        let measuredLabelWidth = ceil(min(maxLabelWidth, max(120, textRect.width)))
        let measuredLabelHeight = ceil(max(28, textRect.height))

        let panelSize = NSSize(
            width: max(minPanelWidth, measuredLabelWidth + (horizontalPadding * 2)),
            height: max(
                minPanelHeight,
                verticalPadding + dotSize + stackSpacing + measuredLabelHeight + verticalPadding
            )
        )

        let dot = NSImageView()
        let image = NSImage(size: NSSize(width: dotSize, height: dotSize))
        image.lockFocus()
        workspace.color.nsColor.set()
        NSBezierPath(
            ovalIn: NSRect(origin: .zero, size: NSSize(width: dotSize, height: dotSize))
        ).fill()
        image.unlockFocus()
        dot.image = image

        let label = NSTextField(labelWithString: workspace.name)
        label.font = labelFont
        label.textColor = .white
        label.alignment = .center
        label.lineBreakMode = .byWordWrapping
        label.maximumNumberOfLines = 0
        label.cell?.wraps = true
        label.translatesAutoresizingMaskIntoConstraints = false

        presentHUD(
            panelSize: panelSize,
            cornerRadius: 24,
            stackSpacing: stackSpacing,
            duration: 1.0,
            content: [dot, label],
            extraConstraints: { _ in
                [label.widthAnchor.constraint(lessThanOrEqualToConstant: maxLabelWidth)]
            }
        )
    }

    func showToggleFeedback(enabled: Bool) {
        let panelSize = NSSize(width: 240, height: 120)

        let icon = NSImageView()
        if let image = NSImage(
            systemSymbolName: enabled ? "checkmark.circle.fill" : "xmark.circle.fill",
            accessibilityDescription: nil
        ) {
            icon.image = image
        }
        icon.contentTintColor = enabled ? .systemGreen : .systemRed
        icon.translatesAutoresizingMaskIntoConstraints = false

        let label = NSTextField(labelWithString: enabled ? "Deks Enabled" : "Deks Disabled")
        label.font = .systemFont(ofSize: 18, weight: .semibold)
        label.textColor = .white
        label.alignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false

        presentHUD(
            panelSize: panelSize,
            cornerRadius: 16,
            stackSpacing: 12,
            duration: 1.5,
            content: [icon, label],
            extraConstraints: { _ in
                [
                    icon.widthAnchor.constraint(equalToConstant: 32),
                    icon.heightAnchor.constraint(equalToConstant: 32),
                ]
            }
        )
    }

    // MARK: - Shared presentation

    private func presentHUD(
        panelSize: NSSize,
        cornerRadius: CGFloat,
        stackSpacing: CGFloat,
        duration: TimeInterval,
        content: [NSView],
        extraConstraints: (NSStackView) -> [NSLayoutConstraint] = { _ in [] }
    ) {
        fadeTimer?.invalidate()
        window?.close()

        let rect = NSRect(origin: .zero, size: panelSize)
        let panel = NSPanel(
            contentRect: rect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .floating
        panel.isFloatingPanel = true
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.center()

        let visualEffect = NSVisualEffectView(frame: rect)
        visualEffect.blendingMode = .behindWindow
        visualEffect.state = .active
        visualEffect.material = .hudWindow
        visualEffect.wantsLayer = true
        visualEffect.layer?.cornerRadius = cornerRadius
        visualEffect.layer?.masksToBounds = true

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = stackSpacing
        stack.translatesAutoresizingMaskIntoConstraints = false
        visualEffect.addSubview(stack)

        for view in content {
            stack.addArrangedSubview(view)
        }

        NSLayoutConstraint.activate(
            [
                stack.centerXAnchor.constraint(equalTo: visualEffect.centerXAnchor),
                stack.centerYAnchor.constraint(equalTo: visualEffect.centerYAnchor),
            ] + extraConstraints(stack)
        )

        panel.contentView = visualEffect
        panel.alphaValue = 0.0
        panel.orderFront(nil)

        self.window = panel

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.15
            panel.animator().alphaValue = 1.0
        }

        fadeTimer = Timer.scheduledTimer(withTimeInterval: duration, repeats: false) {
            [weak self] _ in
            Task { @MainActor in
                self?.fadeOutCurrent()
            }
        }
    }

    private func fadeOutCurrent() {
        guard let w = window else { return }
        NSAnimationContext.runAnimationGroup(
            { context in
                context.duration = 0.3
                w.animator().alphaValue = 0.0
            },
            completionHandler: {
                Task { @MainActor [weak self, weak w] in
                    guard let self, let w else { return }
                    w.close()
                    if self.window === w { self.window = nil }
                }
            }
        )
    }
}
