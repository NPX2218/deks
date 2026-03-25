import AppKit
import Foundation

@MainActor
enum UninstallManager {
    static func confirmAndUninstall() {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Delete Deks?"
        alert.informativeText =
            "This will remove Deks from Applications, clear its local data, and reset Accessibility permission for Deks."
        alert.addButton(withTitle: "Delete Deks")
        alert.addButton(withTitle: "Cancel")

        let response = alert.runModal()
        guard response == .alertFirstButtonReturn else { return }

        performUninstall()
    }

    private static func performUninstall() {
        let script =
            #"sleep 1; pkill -x Deks >/dev/null 2>&1 || true; tccutil reset Accessibility com.neelbansal.deks || true; rm -rf \"/Applications/Deks.app\"; rm -rf \"$HOME/Library/Application Support/Deks\""#
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-lc", script]
        try? process.run()

        NSApp.terminate(nil)
    }
}
