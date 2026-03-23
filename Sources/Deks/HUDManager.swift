import Foundation
import AppKit

@MainActor
class HUDManager {
    static let shared = HUDManager()
    
    private var window: NSWindow?
    private var fadeTimer: Timer?
    
    func show(workspace: Workspace) {
        fadeTimer?.invalidate()
        window?.close()
        
        let size: CGFloat = 200
        let rect = NSRect(x: 0, y: 0, width: size, height: size)
        
        let panel = NSPanel(contentRect: rect, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
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
        
        let dotSize: CGFloat = 40
        let dot = NSImageView()
        let image = NSImage(size: NSSize(width: dotSize, height: dotSize))
        image.lockFocus()
        workspace.color.nsColor.set()
        let path = NSBezierPath(ovalIn: NSRect(origin: .zero, size: NSSize(width: dotSize, height: dotSize)))
        path.fill()
        image.unlockFocus()
        dot.image = image
        
        let label = NSTextField(labelWithString: workspace.name)
        label.font = .systemFont(ofSize: 22, weight: .bold)
        label.textColor = .white
        label.alignment = .center
        label.isEditable = false
        label.isBordered = false
        label.drawsBackground = false
        
        stack.addArrangedSubview(dot)
        stack.addArrangedSubview(label)
        
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: visualEffect.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: visualEffect.centerYAnchor)
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
                NSAnimationContext.runAnimationGroup({ context in
                    context.duration = 0.3
                    w.animator().alphaValue = 0.0
                }, completionHandler: {
                    w.close()
                    if self.window === w { self.window = nil }
                })
            }
        }
    }
}
