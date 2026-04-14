import Foundation

/// Pure, side-effect-free transformations on the `Workspace` list. Extracted
/// from `WorkspaceManager` so the core data mutations can be unit tested
/// without spinning up AppKit, the window tracker, or the hotkey system.
enum WorkspaceMutations {

    /// Returns a new workspaces array in which `windowID` has been moved to
    /// the front (index 0) of the workspace at `targetIndex`. The window is
    /// first removed from every workspace that currently owns it so the
    /// result never contains duplicates.
    ///
    /// If the window already exists in *any* workspace, its existing
    /// `WindowRef` is reused so flags like `isPinned` survive the move.
    /// If it doesn't exist yet, `fallbackRef` is inserted.
    ///
    /// An out-of-range `targetIndex` is a no-op and returns the input unchanged.
    static func moveWindowToFront(
        of workspaces: [Workspace],
        windowID: UUID,
        targetIndex: Int,
        fallbackRef: WindowRef
    ) -> [Workspace] {
        guard targetIndex >= 0, targetIndex < workspaces.count else {
            return workspaces
        }

        var result = workspaces
        var extractedRef: WindowRef?

        for i in result.indices {
            // Record the first existing ref so we can preserve its pinned
            // state, then strip ALL matching refs from this workspace to
            // guarantee the result never contains duplicates.
            if extractedRef == nil,
                let existing = result[i].assignedWindows.first(where: { $0.id == windowID })
            {
                extractedRef = existing
            }
            result[i].assignedWindows.removeAll { $0.id == windowID }
        }

        let refToInsert = extractedRef ?? fallbackRef
        result[targetIndex].assignedWindows.insert(refToInsert, at: 0)
        return result
    }

    /// Returns the index of the workspace currently owning `windowID`, or
    /// `nil` if no workspace does. The first match wins; callers should
    /// ensure uniqueness via `moveWindowToFront` so this is always the only
    /// match in practice.
    static func owningWorkspaceIndex(
        of windowID: UUID,
        in workspaces: [Workspace]
    ) -> Int? {
        for (i, ws) in workspaces.enumerated() {
            if ws.assignedWindows.contains(where: { $0.id == windowID }) {
                return i
            }
        }
        return nil
    }

    /// Whether `windowID` is assigned to the currently-active workspace. Used
    /// by the settings live-preview so a single dragged window can decide
    /// whether to hide or show itself on screen.
    static func isWindowAssignedToActive(
        windowID: UUID,
        activeId: UUID?,
        workspaces: [Workspace]
    ) -> Bool {
        guard let activeId,
            let active = workspaces.first(where: { $0.id == activeId })
        else { return false }
        return active.assignedWindows.contains(where: { $0.id == windowID })
    }

    /// Returns a new workspaces array with `windowID` removed from every
    /// workspace that owns it. Used by callers that want to drop a window
    /// entirely without reassigning it.
    static func removeWindow(
        _ windowID: UUID,
        from workspaces: [Workspace]
    ) -> [Workspace] {
        var result = workspaces
        for i in result.indices {
            result[i].assignedWindows.removeAll { $0.id == windowID }
        }
        return result
    }
}
