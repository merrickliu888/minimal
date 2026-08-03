import SwiftUI

/// Conventional onboarding/settings window: macOS permissions and the
/// Claude Code connection. The runtime experience stays in the overlay.
struct SettingsView: View {
    @EnvironmentObject var permissions: PermissionsManager
    @ObservedObject var settingsModel: SettingsModel

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Assistant Setup")
                    .font(.title2.weight(.semibold))
                Text("Grant the required permissions and connect Claude Code, then summon the overlay with ⌥Space from any app.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }

            GroupBox("Permissions — all required") {
                VStack(spacing: 10) {
                    permissionRow(
                        title: "Microphone",
                        detail: "Captures your voice for prompts",
                        status: permissions.microphone,
                        action: { permissions.requestMicrophone() },
                        settingsPane: "Privacy_Microphone"
                    )
                    permissionRow(
                        title: "Speech Recognition",
                        detail: "Transcribes voice into agent prompts",
                        status: permissions.speech,
                        action: { permissions.requestSpeech() },
                        settingsPane: "Privacy_SpeechRecognition"
                    )
                    permissionRow(
                        title: "Screen Recording",
                        detail: "Attaches a screenshot of your display as agent context",
                        status: permissions.screenRecording,
                        action: { permissions.requestScreenRecording() },
                        settingsPane: "Privacy_ScreenCapture",
                        // CGPreflight can't distinguish "never asked" from
                        // "denied", and the app only appears in the Settings
                        // list after it attempts a capture — so always offer
                        // the request path.
                        alwaysOfferRequest: true
                    )
                }
                .padding(.vertical, 4)
            }

            GroupBox("Claude Code") {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 8) {
                        Circle()
                            .fill(settingsModel.health?.isConnected == true ? Color.green : Theme.failure)
                            .frame(width: 9, height: 9)
                        Text(settingsModel.health?.isConnected == true ? "Connected" : "Not connected")
                            .font(.system(size: 12, weight: .medium))
                        if settingsModel.checking {
                            ProgressView().controlSize(.small).padding(.leading, 4)
                        }
                        Spacer()
                        Button("Recheck") { settingsModel.recheck() }
                            .controlSize(.small)
                    }
                    if let health = settingsModel.health {
                        if health.isConnected {
                            Text(health.detail)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        } else {
                            VStack(alignment: .leading, spacing: 3) {
                                if let error = health.errorMessage {
                                    Text(error).font(.system(size: 11)).foregroundStyle(Theme.failure)
                                }
                                if let fix = health.remediation {
                                    Text(fix).font(.system(size: 11)).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                    LabeledContent("Executable path (optional)") {
                        TextField("auto-detect", text: $settingsModel.configuredPath)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 11, design: .monospaced))
                            .onSubmit { settingsModel.saveAndRecheck() }
                    }
                    LabeledContent("Agent working directory") {
                        TextField(NSHomeDirectory(), text: $settingsModel.workingDirectory)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 11, design: .monospaced))
                            .onSubmit { settingsModel.saveWorkingDirectory() }
                    }
                }
                .padding(.vertical, 4)
            }

            HStack {
                if permissions.allGranted && settingsModel.health?.isConnected == true {
                    Label("Ready — press ⌥Space anywhere to start an agent, ⌥Tab to manage agents.", systemImage: "checkmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(.green)
                } else {
                    Label("The overlay is disabled until everything above is green.", systemImage: "exclamationmark.circle")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
        }
        .padding(22)
        .frame(width: 540)
        .onAppear {
            permissions.refresh()
            permissions.startPolling()
            settingsModel.recheck()
        }
        .onDisappear { permissions.stopPolling() }
    }

    @ViewBuilder
    private func permissionRow(
        title: String,
        detail: String,
        status: PermissionsManager.Status,
        action: @escaping () -> Void,
        settingsPane: String,
        alwaysOfferRequest: Bool = false
    ) -> some View {
        HStack {
            Image(systemName: status == .granted ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(status == .granted ? .green : .secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 12, weight: .medium))
                Text(detail).font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Spacer()
            if status != .granted {
                if status == .denied && !alwaysOfferRequest {
                    Button("Open Settings") { permissions.openSettingsPane(settingsPane) }
                        .controlSize(.small)
                } else {
                    Button("Grant") { action() }
                        .controlSize(.small)
                }
            }
        }
    }
}

/// Backing model for the settings window.
@MainActor
final class SettingsModel: ObservableObject {
    @Published var health: ProviderHealth?
    @Published var checking = false
    @Published var configuredPath: String
    @Published var workingDirectory: String

    private let provider: AgentProvider

    init(provider: AgentProvider) {
        self.provider = provider
        configuredPath = UserDefaults.standard.string(forKey: ClaudeCodeProvider.configuredPathKey) ?? ""
        workingDirectory = UserDefaults.standard.string(forKey: AgentCoordinator.workingDirectoryKey) ?? ""
    }

    func recheck() {
        checking = true
        Task { @MainActor in
            health = await provider.checkHealth()
            checking = false
        }
    }

    func saveAndRecheck() {
        let trimmed = configuredPath.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty {
            UserDefaults.standard.removeObject(forKey: ClaudeCodeProvider.configuredPathKey)
        } else {
            UserDefaults.standard.set(trimmed, forKey: ClaudeCodeProvider.configuredPathKey)
        }
        recheck()
    }

    func saveWorkingDirectory() {
        let trimmed = workingDirectory.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty {
            UserDefaults.standard.removeObject(forKey: AgentCoordinator.workingDirectoryKey)
        } else {
            UserDefaults.standard.set((trimmed as NSString).expandingTildeInPath, forKey: AgentCoordinator.workingDirectoryKey)
        }
    }
}
