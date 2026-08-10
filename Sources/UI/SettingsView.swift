import SwiftUI

/// Conventional onboarding/settings window: macOS permissions and coding
/// harness connections. The runtime experience stays in the overlay.
struct SettingsView: View {
    @EnvironmentObject var permissions: PermissionsManager
    @ObservedObject var settingsModel: SettingsModel

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Minimal Setup")
                    .font(.title2.weight(.semibold))
                Text("Grant the required permissions and connect at least one coding harness, then summon the overlay with ⌥Space from any app.")
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
                }
                .padding(.vertical, 4)
            }

            GroupBox("Coding harnesses — one required") {
                VStack(alignment: .leading, spacing: 10) {
                    harnessRow(
                        harness: .codex,
                        configuredPath: $settingsModel.codexConfiguredPath
                    )
                    Divider().opacity(0.4)
                    harnessRow(
                        harness: .claudeCode,
                        configuredPath: $settingsModel.claudeConfiguredPath
                    )
                }
                .padding(.vertical, 4)
            }

            HStack {
                if permissions.allGranted && settingsModel.hasConnectedProvider {
                    Label("Ready — press ⌥Space anywhere to start an agent, ⌥Tab to manage agents.", systemImage: "checkmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(.green)
                } else {
                    Label("The overlay needs both permissions and at least one connected harness.", systemImage: "exclamationmark.circle")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
        }
        .padding(22)
        .frame(width: 540, alignment: .top)
        .frame(maxHeight: .infinity, alignment: .top)
        .onAppear {
            permissions.refresh()
            permissions.startPolling()
            settingsModel.recheck()
        }
        .onDisappear { permissions.stopPolling() }
    }

    @ViewBuilder
    private func harnessRow(harness: AgentHarness, configuredPath: Binding<String>) -> some View {
        let health = settingsModel.health[harness.rawValue]
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Circle()
                    .fill(health?.isConnected == true ? Color.green : Theme.failure)
                    .frame(width: 9, height: 9)
                Text(harness.displayName)
                    .font(.system(size: 12, weight: .medium))
                Text(health?.isConnected == true ? "Connected" : "Not connected")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                if settingsModel.checking {
                    ProgressView().controlSize(.small).padding(.leading, 4)
                }
                Spacer()
                Button("Recheck") { settingsModel.recheck() }
                    .controlSize(.small)
            }
            if let health {
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
                TextField("auto-detect", text: configuredPath)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 11, design: .monospaced))
                    .onSubmit { settingsModel.savePathsAndRecheck() }
            }
        }
    }

    @ViewBuilder
    private func permissionRow(
        title: String,
        detail: String,
        status: PermissionsManager.Status,
        action: @escaping () -> Void,
        settingsPane: String
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
                if status == .denied {
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
    @Published var health: [String: ProviderHealth] = [:]
    @Published var checking = false
    @Published var claudeConfiguredPath: String
    @Published var codexConfiguredPath: String

    private let providers: [AgentProvider]

    init(providers: [AgentProvider]) {
        self.providers = providers
        claudeConfiguredPath = UserDefaults.standard.string(forKey: ClaudeCodeProvider.configuredPathKey) ?? ""
        codexConfiguredPath = UserDefaults.standard.string(forKey: CodexProvider.configuredPathKey) ?? ""
    }

    var hasConnectedProvider: Bool {
        health.values.contains { $0.isConnected }
    }

    func recheck() {
        checking = true
        Task { @MainActor in
            await checkAll()
            checking = false
        }
    }

    func checkAll() async {
        var results: [String: ProviderHealth] = [:]
        for provider in providers {
            results[provider.id] = await provider.checkHealth()
        }
        health = results
    }

    func savePathsAndRecheck() {
        savePath(claudeConfiguredPath, key: ClaudeCodeProvider.configuredPathKey)
        savePath(codexConfiguredPath, key: CodexProvider.configuredPathKey)
        recheck()
    }

    private func savePath(_ path: String, key: String) {
        let trimmed = path.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty {
            UserDefaults.standard.removeObject(forKey: key)
        } else {
            UserDefaults.standard.set(trimmed, forKey: key)
        }
    }
}
