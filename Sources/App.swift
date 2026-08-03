import SwiftUI

@main
struct AssistantApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        MenuBarExtra {
            MenuBarView()
                .environmentObject(appDelegate.store)
                .environmentObject(appDelegate.permissions)
        } label: {
            Image(systemName: "circle.hexagongrid.fill")
        }
    }
}

struct MenuBarView: View {
    @EnvironmentObject var store: SessionStore
    @EnvironmentObject var permissions: PermissionsManager

    var body: some View {
        let needsInput = store.panelSessions.filter { $0.state == .needsInput }.count
        let running = store.panelSessions.filter { $0.state == .running }.count

        Group {
            Text(statusLine(needsInput: needsInput, running: running))
            Divider()
            Button("New Agent  ⌥Space") {
                (NSApp.delegate as? AppDelegate)?.overlayController.handleHotkey(.promptEntry)
            }
            Button("Manage Agents  ⌥Tab") {
                (NSApp.delegate as? AppDelegate)?.overlayController.handleHotkey(.management)
            }
            Divider()
            Button("Settings…") {
                (NSApp.delegate as? AppDelegate)?.showSettingsWindow()
            }
            Button("Quit Assistant") {
                NSApp.terminate(nil)
            }
        }
    }

    private func statusLine(needsInput: Int, running: Int) -> String {
        if needsInput > 0 { return "\(needsInput) agent\(needsInput == 1 ? "" : "s") need\(needsInput == 1 ? "s" : "") input" }
        if running > 0 { return "\(running) agent\(running == 1 ? "" : "s") running" }
        return "No active agents"
    }
}
