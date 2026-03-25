import AppKit
import Foundation

@MainActor
class HUDManager {
    static let shared = HUDManager()

    private var window: NSWindow?
    private var fadeTimer: Timer?

    func show(workspace: Workspace) {
        fadeTimer?.invalidate()
        window?.close()

        let dotSize: CGFloat = 40
        let stackSpacing: CGFloat = 20
        let horizontalPadding: CGFloat = 28
        let verticalPadding: CGFloat = 24
        let minPanelWidth: CGFloat = 220
        let minPanelHeight: CGFloat = 200

        let screenWidth = NSScreen.main?.visibleFrame.width ?? 1200
        let maxPanelWidth = min(420, screenWidth * 0.45)
        let maxLabelWidth = max(160, maxPanelWidth - (horizontalPadding * 2))

        let labelFont = NSFont.systemFont(ofSize: 22, weight: .bold)
        let textRect = (workspace.name as NSString).boundingRect(
            with: NSSize(width: maxLabelWidth, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: labelFont]
        )
        let measuredLabelWidth = ceil(min(maxLabelWidth, max(120, textRect.width)))
        let measuredLabelHeight = ceil(max(28, textRect.height))

        let panelWidth = max(minPanelWidth, measuredLabelWidth + (horizontalPadding * 2))
        let panelHeight = max(
            minPanelHeight,
            verticalPadding + dotSize + stackSpacing + measuredLabelHeight + verticalPadding
        )
        let rect = NSRect(x: 0, y: 0, width: panelWidth, height: panelHeight)

        let panel = NSPanel(
            contentRect: rect, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered,
            defer: false)
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
        visualEffect.layer?.cornerRadius = 24
        visualEffect.layer?.masksToBounds = true

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 20
        stack.translatesAutoresizingMaskIntoConstraints = false
        visualEffect.addSubview(stack)

        let dot = NSImageView()
        let image = NSImage(size: NSSize(width: dotSize, height: dotSize))
        image.lockFocus()
        workspace.color.nsColor.set()
        let path = NSBezierPath(
            ovalIn: NSRect(origin: .zero, size: NSSize(width: dotSize, height: dotSize)))
        path.fill()
        image.unlockFocus()
        dot.image = image

        let label = NSTextField(labelWithString: workspace.name)
        label.font = labelFont
        label.textColor = .white
        label.alignment = .center
        label.isEditable = false
        label.isBordered = false
        label.drawsBackground = false
        label.lineBreakMode = .byWordWrapping
        label.maximumNumberOfLines = 0
        label.cell?.wraps = true
        label.translatesAutoresizingMaskIntoConstraints = false

        stack.addArrangedSubview(dot)
        stack.addArrangedSubview(label)

        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: visualEffect.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: visualEffect.centerYAnchor),
            label.widthAnchor.constraint(lessThanOrEqualToConstant: maxLabelWidth),
        ])

        panel.contentView = visualEffect
        panel.alphaValue = 0.0
        panel.orderFront(nil)

        self.window = panel

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.15
            panel.animator().alphaValue = 1.0
        }

        fadeTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self = self, let w = self.window else { return }
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
                    })
            }
        }
    }

    func showToggleFeedback(enabled: Bool) {
        fadeTimer?.invalidate()
        window?.close()

        let statusText = enabled ? "Deks Enabled" : "Deks Disabled"
        let iconName = enabled ? "checkmark.circle.fill" : "xmark.circle.fill"

        let panelWidth: CGFloat = 240
        let panelHeight: CGFloat = 120
        let rect = NSRect(x: 0, y: 0, width: panelWidth, height: panelHeight)

        let panel = NSPanel(
            contentRect: rect, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered,
            defer: false)
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
        visualEffect.layer?.cornerRadius = 16
        visualEffect.layer?.masksToBounds = true

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        visualEffect.addSubview(stack)

        let label = NSTextField(labelWithString: statusText)
        label.font = NSFont.systemFont(ofSize: 18, weight: .semibold)
        label.textColor = .white
        label.alignment = .center

        let icon = NSImageView()
        if let image = NSImage(systemSymbolName: iconName, accessibilityDescription: nil) {
            icon.image = image
            icon.contentTintColor = enabled ? .systemGreen : .systemRed
            icon.translatesAutoresizingMaskIntoConstraints = false
            stack.addArrangedSubview(icon)
            NSLayoutConstraint.activate([
                icon.widthAnchor.constraint(equalToConstant: 32),
                icon.heightAnchor.constraint(equalToConstant: 32),
            ])
        }

        label.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(label)

        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: visualEffect.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: visualEffect.centerYAnchor),
        ])

        panel.contentView = visualEffect
        panel.alphaValue = 0.0
        panel.orderFront(nil)

        self.window = panel

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.15
            panel.animator().alphaValue = 1.0
        }

        fadeTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self = self, let w = self.window else { return }
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
                    })
            }
        }
    }
}
