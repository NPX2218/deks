import AppKit
import Carbon.HIToolbox
import Foundation

@MainActor
class HotkeyManager {
    static let shared = HotkeyManager()

    private static let hotKeySignature: OSType = {
        var result: OSType = 0
        for scalar in "DEKS".unicodeScalars {
            result = (result << 8) + OSType(scalar.value)
        }
        return result
    }()

    private static let hotKeyHandler: EventHandlerUPP = { _, eventRef, userData in
        guard let eventRef, let userData else { return noErr }
        let manager = Unmanaged<HotkeyManager>.fromOpaque(userData).takeUnretainedValue()

        var hotKeyID = EventHotKeyID()
        let status = GetEventParameter(
            eventRef,
            EventParamName(kEventParamDirectObject),
            EventParamType(typeEventHotKeyID),
            nil,
            MemoryLayout<EventHotKeyID>.size,
            nil,
            &hotKeyID
        )
        guard status == noErr, hotKeyID.signature == HotkeyManager.hotKeySignature else {
            return noErr
        }

        let resolvedID = hotKeyID.id
        Task { @MainActor in
            manager.handleCarbonHotKeyID(resolvedID)
        }
        return noErr
    }

    private var eventHandlerRef: EventHandlerRef?
    private var registeredHotKeyRefs: [EventHotKeyRef] = []
    private var comboByHotKeyID: [UInt32: HotkeyCombo] = [:]
    private var nextHotKeyID: UInt32 = 1

    // Maps a hotkey to a workspace ID
    private var bindings: [HotkeyCombo: UUID] = [:]

    // Maps a hotkey to a generic action
    private var callbacks: [HotkeyCombo: () -> Void] = [:]

    private func triggerHotkey(_ combo: HotkeyCombo) {
        if let workspaceId = bindings[combo] {
            WorkspaceManager.shared.switchTo(
                workspaceId: workspaceId,
                force: true,
                source: "hotkey"
            )
        } else if let action = callbacks[combo] {
            action()
        }
    }

    private func carbonModifiers(from rawModifiers: UInt) -> UInt32 {
        let flags = NSEvent.ModifierFlags(rawValue: rawModifiers)
        var result: UInt32 = 0
        if flags.contains(.command) { result |= UInt32(cmdKey) }
        if flags.contains(.option) { result |= UInt32(optionKey) }
        if flags.contains(.control) { result |= UInt32(controlKey) }
        if flags.contains(.shift) { result |= UInt32(shiftKey) }
        return result
    }

    private func installHotKeyHandlerIfNeeded() {
        guard eventHandlerRef == nil else { return }

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let status = InstallEventHandler(
            GetApplicationEventTarget(),
            Self.hotKeyHandler,
            1,
            &eventType,
            Unmanaged.passUnretained(self).toOpaque(),
            &eventHandlerRef
        )

        if status != noErr {
            TelemetryManager.shared.record(
                event: "hotkey_handler_install_failed",
                level: "warning",
                metadata: ["status": String(status)]
            )
        }
    }

    private func unregisterAllHotKeys() {
        for ref in registeredHotKeyRefs {
            UnregisterEventHotKey(ref)
        }
        registeredHotKeyRefs.removeAll()
        comboByHotKeyID.removeAll()
        nextHotKeyID = 1
    }

    private func registerSystemHotkeys() {
        installHotKeyHandlerIfNeeded()
        unregisterAllHotKeys()

        let allCombos = Set(bindings.keys).union(callbacks.keys)
        for combo in allCombos {
            var hotKeyRef: EventHotKeyRef?
            let hotKeyID = EventHotKeyID(signature: Self.hotKeySignature, id: nextHotKeyID)
            let status = RegisterEventHotKey(
                UInt32(combo.keyCode),
                carbonModifiers(from: combo.modifiers),
                hotKeyID,
                GetApplicationEventTarget(),
                0,
                &hotKeyRef
            )

            if status == noErr, let hotKeyRef {
                comboByHotKeyID[nextHotKeyID] = combo
                registeredHotKeyRefs.append(hotKeyRef)
                nextHotKeyID += 1
            } else {
                TelemetryManager.shared.record(
                    event: "hotkey_register_failed",
                    level: "warning",
                    metadata: [
                        "status": String(status),
                        "keyCode": String(combo.keyCode),
                        "modifiers": String(combo.modifiers),
                    ]
                )
            }
        }
    }

    private func handleCarbonHotKeyID(_ id: UInt32) {
        guard let combo = comboByHotKeyID[id] else { return }
        triggerHotkey(combo)
    }

    func resetAllHotkeys() {
        bindings.removeAll()
        callbacks.removeAll()
        registerSystemHotkeys()
    }

    func register(hotkey: HotkeyCombo, for workspaceId: UUID) {
        bindings[hotkey] = workspaceId
        registerSystemHotkeys()
    }

    func registerGlobalCallback(hotkey: HotkeyCombo, action: @escaping () -> Void) {
        callbacks[hotkey] = action
        registerSystemHotkeys()
    }
}
