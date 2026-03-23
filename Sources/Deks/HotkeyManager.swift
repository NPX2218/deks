import AppKit
import Foundation

@MainActor
class HotkeyManager {
    static let shared = HotkeyManager()

    // We hold strong references to event monitors so they aren't deallocated
    private var globalMonitors: [Any] = []

    // Maps a hotkey to a workspace ID
    private var bindings: [HotkeyCombo: UUID] = [:]

    // Maps a hotkey to a generic action
    private var callbacks: [HotkeyCombo: () -> Void] = [:]

    func resetAllHotkeys() {
        bindings.removeAll()
        callbacks.removeAll()
        setupGlobalMonitors()
    }

    func register(hotkey: HotkeyCombo, for workspaceId: UUID) {
        bindings[hotkey] = workspaceId
        setupGlobalMonitors()
    }

    func registerGlobalCallback(hotkey: HotkeyCombo, action: @escaping () -> Void) {
        callbacks[hotkey] = action
        setupGlobalMonitors()
    }

    private func setupGlobalMonitors() {
        // Clear old monitors
        for monitor in globalMonitors {
            NSEvent.removeMonitor(monitor)
        }
        globalMonitors.removeAll()

        let monitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self = self else { return }
            // Strip out non-essential modifiers
            let targetFlags = event.modifierFlags.intersection([
                .control, .option, .command, .shift,
            ])
            let exactCombo = HotkeyCombo(modifiers: targetFlags.rawValue, keyCode: event.keyCode)

            if let workspaceId = self.bindings[exactCombo] {
                WorkspaceManager.shared.switchTo(workspaceId: workspaceId)
            } else if let action = self.callbacks[exactCombo] {
                action()
            }
        }

        if let monitor = monitor {
            globalMonitors.append(monitor)
        }
    }
}
