import AppKit
import AVFoundation
import Combine
import Foundation
import ScreenCaptureKit
import Speech

/// Tracks and requests the macOS permissions the app cannot function
/// without: microphone, speech recognition, and screen recording.
@MainActor
final class PermissionsManager: ObservableObject {

    enum Status: Equatable {
        case unknown
        case granted
        case denied
        case notDetermined
    }

    @Published private(set) var microphone: Status = .unknown
    @Published private(set) var speech: Status = .unknown
    @Published private(set) var screenRecording: Status = .unknown

    var allGranted: Bool {
        microphone == .granted && speech == .granted && screenRecording == .granted
    }

    private var pollTimer: Timer?

    func refresh() {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: microphone = .granted
        case .notDetermined: microphone = .notDetermined
        default: microphone = .denied
        }
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized: speech = .granted
        case .notDetermined: speech = .notDetermined
        default: speech = .denied
        }
        screenRecording = CGPreflightScreenCaptureAccess() ? .granted : .denied
    }

    func requestMicrophone() {
        AVCaptureDevice.requestAccess(for: .audio) { _ in
            Task { @MainActor in self.refresh() }
        }
    }

    func requestSpeech() {
        SFSpeechRecognizer.requestAuthorization { _ in
            Task { @MainActor in self.refresh() }
        }
    }

    func requestScreenRecording() {
        // ScreenCaptureKit triggers the modern Sequoia permission dialog and
        // correctly attributes it to this app; CGRequestScreenCaptureAccess
        // only works once per launch.
        SCShareableContent.getExcludingDesktopWindows(false, onScreenWindowsOnly: false) { _, _ in
            Task { @MainActor in
                self.refresh()
                if self.screenRecording != .granted {
                    self.openSettingsPane("Privacy_ScreenCapture")
                }
            }
        }
    }

    func openSettingsPane(_ pane: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") {
            NSWorkspace.shared.open(url)
        }
    }

    /// macOS sends no notification when the user grants a permission in
    /// System Settings, so poll while onboarding is visible.
    func startPolling() {
        stopPolling()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { _ in
            Task { @MainActor in
                self.refresh()
                if self.allGranted { self.stopPolling() }
            }
        }
    }

    func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
    }
}
