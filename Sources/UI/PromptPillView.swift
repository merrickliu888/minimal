import SwiftUI

/// Bottom-center overlay: the agent management card stacked directly above
/// the prompt pill (same width), which shows a waveform while listening and
/// an editable text field once the user types.
struct PromptPillView: View {
    @EnvironmentObject var controller: OverlayController
    @EnvironmentObject var transcriber: Transcriber
    @FocusState private var fieldFocused: Bool

    private var isTranscribing: Bool {
        if case .promptEntry(transcribing: true) = controller.mode { return true }
        return false
    }

    /// False while the pill is visible but the management panel has focus.
    private var isFocused: Bool {
        if case .promptEntry = controller.mode { return true }
        return false
    }

    var body: some View {
        VStack(spacing: 12) {
            Spacer()
            if controller.suggestionPopupVisible && controller.suggestionField == .pill {
                // While an @/-token is being typed, the suggestions take the
                // management card's slot above the pill.
                SuggestionPopupView()
            } else if controller.mode == .projectPicker {
                ProjectPickerView()
            } else if controller.mode == .modelPicker {
                ModelPickerView()
            } else {
                AgentPanelView()
            }
            Group {
                if isTranscribing {
                    listeningPill
                } else {
                    editingField
                }
            }
            .animation(.spring(response: 0.3, dampingFraction: 0.85), value: isTranscribing)
        }
        .padding(.bottom, 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Listening state

    private var listeningPill: some View {
        HStack(spacing: 12) {
            // Unmistakable recording indicator.
            Circle()
                .fill(Color.red)
                .frame(width: 8, height: 8)
                .opacity(0.9)
                .modifier(PulseEffect())

            WaveformView(level: transcriber.audioLevel)
                .frame(width: 88, height: 24)

            Group {
                if let error = transcriber.lastError {
                    Text(error)
                        .foregroundStyle(Theme.failure)
                        .lineLimit(3)
                } else if !transcriber.isActive {
                    Text("Starting microphone…")
                        .foregroundStyle(Theme.textSecondary)
                } else if controller.draftText.isEmpty {
                    Text("Listening… speak, or start typing")
                        .foregroundStyle(Theme.textSecondary)
                } else {
                    Text(controller.draftText)
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(2)
                }
            }
            .font(.system(size: 14))
            .frame(maxWidth: 320, alignment: .leading)

            KeyHint(symbol: "⏎", label: "start agent")
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .overlayCard(cornerRadius: Theme.pillRadius)
        .fixedSize(horizontal: true, vertical: true)
    }

    // MARK: Editing state

    private var editingField: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("Describe what the agent should do…", text: $controller.draftText, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 14))
                .lineLimit(1...5)
                .focused($fieldFocused)
                // Don't grab the caret while the management card above has
                // focus; Tab routes focus back explicitly.
                .onAppear { fieldFocused = isFocused }
                .onChange(of: isFocused) { _, focused in fieldFocused = focused }

            HStack(spacing: 14) {
                if isFocused {
                    KeyHint(symbol: "⌘D", label: "voice")
                    KeyHint(symbol: "⌘P", label: "project")
                    KeyHint(symbol: "⌘M", label: "model")
                } else {
                    KeyHint(symbol: "⇥", label: "focus")
                }
                Spacer()
                HStack(spacing: 4) {
                    Image(systemName: "cpu")
                        .font(.system(size: 9))
                    Text(controller.pillModelDisplay)
                        .font(.system(size: 10, design: .monospaced))
                }
                .foregroundStyle(controller.draftModel == nil ? Theme.textSecondary : Theme.accent)
                HStack(spacing: 4) {
                    Image(systemName: "folder")
                        .font(.system(size: 9))
                    Text(controller.pillWorkingDirectoryDisplay)
                        .font(.system(size: 10, design: .monospaced))
                        .lineLimit(1)
                }
                .foregroundStyle(Theme.textSecondary)
                .help(controller.pillWorkingDirectoryFullPath)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .frame(width: 560)
        .overlayCard(cornerRadius: 18)
    }
}

/// Symmetric center-weighted level bars.
struct WaveformView: View {
    var level: Float
    private let weights: [CGFloat] = [0.35, 0.55, 0.78, 0.95, 1.0, 0.95, 0.78, 0.55, 0.35]

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timeline in
            let time = timeline.date.timeIntervalSinceReferenceDate
            HStack(spacing: 3) {
                ForEach(weights.indices, id: \.self) { i in
                    let travel = 0.5 + 0.5 * sin(time * 6.2 - Double(i) * 0.78)
                    let base = CGFloat(level) * weights[i]
                    let liveliness = (1 - base) * CGFloat(0.06 + travel * 0.16)
                    let height = max(3, (base + liveliness) * 24)
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(Theme.accent)
                        .frame(width: 3, height: height)
                }
            }
            .frame(height: 24)
        }
    }
}

struct PulseEffect: ViewModifier {
    @State private var pulsing = false
    func body(content: Content) -> some View {
        content
            .scaleEffect(pulsing ? 1.25 : 0.9)
            .animation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true), value: pulsing)
            .onAppear { pulsing = true }
    }
}
