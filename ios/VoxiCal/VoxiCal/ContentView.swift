import SwiftUI
import Combine

// MARK: - ContentView

struct ContentView: View {
    @Environment(CalendarViewModel.self) private var viewModel

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {

                // Orange banner when Foundation Models is unavailable
                if !viewModel.isModelAvailable, let msg = viewModel.errorMessage {
                    ModelUnavailableBanner(message: msg)
                }

                // Scrollable chat history
                MessageScrollView()

                Divider()

                // Input — swaps between idle layout and recording layout
                InputAreaView()
            }
            .navigationTitle("VoxiCal")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                #if DEBUG
                ToolbarItem(placement: .topBarLeading) {
                    Menu {
                        Button {
                            Task { _ = await runEvaluationSuite() }
                        } label: {
                            Label("Run Evals", systemImage: "checkmark.circle")
                        }
                    } label: {
                        Image(systemName: "testtube.2")
                    }
                }
                #endif
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        viewModel.clearConversation()
                    } label: {
                        Image(systemName: "square.and.pencil")
                    }
                    .disabled(viewModel.isProcessing)
                }
            }
        }
        // Calendar access denied alert
        .alert(
            "Calendar Access Required",
            isPresented: Binding(
                get: { viewModel.showSettingsAlert },
                set: { viewModel.showSettingsAlert = $0 }
            )
        ) {
            Button("Open Settings") {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("VoxiCal needs full calendar access. Enable it in Settings → Privacy & Security → Calendars.")
        }
    }
}

// MARK: - MessageScrollView

private struct MessageScrollView: View {
    @Environment(CalendarViewModel.self) private var viewModel

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 12) {
                    ForEach(viewModel.messages) { message in
                        ChatBubbleView(message: message)
                    }

                    // Animated typing indicator while the LLM is responding
                    if viewModel.isProcessing {
                        TypingIndicatorView()
                            .transition(.opacity.combined(with: .move(edge: .bottom)))
                    }

                    // Invisible zero-height anchor used by scrollTo
                    Color.clear
                        .frame(height: 1)
                        .id("bottom")
                }
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, 8)
                .animation(.easeOut(duration: 0.25), value: viewModel.messages.count)
                .animation(.easeOut(duration: 0.25), value: viewModel.isProcessing)
            }
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: viewModel.messages.count) {
                withAnimation(.easeOut(duration: 0.25)) {
                    proxy.scrollTo("bottom")
                }
            }
            .onChange(of: viewModel.isProcessing) {
                withAnimation(.easeOut(duration: 0.25)) {
                    proxy.scrollTo("bottom")
                }
            }
        }
    }
}

// MARK: - ChatBubbleView

private struct ChatBubbleView: View {
    let message: ChatMessage

    private var isUser: Bool { message.role == .user }

    var body: some View {
        HStack(alignment: .bottom, spacing: 0) {
            if isUser { Spacer(minLength: 60) }

            VStack(alignment: isUser ? .trailing : .leading, spacing: 4) {
                Text(message.text)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(isUser ? Color.accentColor : Color(.secondarySystemBackground))
                    .foregroundStyle(isUser ? .white : .primary)
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))

                Text(message.timestamp, style: .time)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 4)
            }

            if !isUser { Spacer(minLength: 60) }
        }
    }
}

// MARK: - TypingIndicatorView

private struct TypingIndicatorView: View {
    @State private var activeIndex = 0

    private let timer = Timer.publish(every: 0.38, on: .main, in: .common).autoconnect()

    var body: some View {
        HStack {
            HStack(spacing: 6) {
                ForEach(0..<3, id: \.self) { i in
                    Circle()
                        .frame(width: 9, height: 9)
                        .foregroundStyle(i == activeIndex ? Color.primary : Color(.tertiaryLabel))
                        .scaleEffect(i == activeIndex ? 1.25 : 0.9)
                        .animation(.spring(duration: 0.25), value: activeIndex)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(Color(.secondarySystemBackground))
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))

            Spacer(minLength: 60)
        }
        .onReceive(timer) { _ in
            activeIndex = (activeIndex + 1) % 3
        }
    }
}

// MARK: - InputAreaView

private struct InputAreaView: View {
    @Environment(CalendarViewModel.self) private var viewModel
    @State private var inputText = ""
    @FocusState private var isTextFieldFocused: Bool

    private var isRecordingOrPaused: Bool {
        viewModel.speechService.recordingState != .idle
    }

    var body: some View {
        Group {
            if isRecordingOrPaused {
                RecordingInputRow(inputText: $inputText)
            } else {
                IdleInputRow(inputText: $inputText, fieldFocus: $isTextFieldFocused)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(.regularMaterial)
        // Animate the swap between idle ↔ recording layouts
        .animation(.easeInOut(duration: 0.2), value: isRecordingOrPaused)
    }
}

// MARK: - IdleInputRow

private struct IdleInputRow: View {
    @Environment(CalendarViewModel.self) private var viewModel
    @Binding var inputText: String
    var fieldFocus: FocusState<Bool>.Binding

    private var canSend: Bool {
        !inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !viewModel.isProcessing
    }

    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            // Text input field
            TextField("Ask about your calendar…", text: $inputText, axis: .vertical)
                .lineLimit(1...5)
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .background(Color(.tertiarySystemBackground))
                .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                .focused(fieldFocus)
                .disabled(viewModel.isProcessing)
                .submitLabel(.send)
                .onSubmit { sendText() }

            // Mic button — starts voice recording
            Button {
                fieldFocus.wrappedValue = false
                Task { await startRecording() }
            } label: {
                Image(systemName: "mic.fill")
                    .font(.system(size: 19, weight: .medium))
                    .frame(width: 44, height: 44)
                    .background(Color(.tertiarySystemBackground))
                    .clipShape(Circle())
                    .foregroundStyle(.secondary)
            }
            .disabled(viewModel.isProcessing)

            // Send button — appears only when there is text
            if canSend {
                Button { sendText() } label: {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 36))
                        .foregroundStyle(Color.accentColor)
                }
                .transition(.scale(scale: 0.7).combined(with: .opacity))
            }
        }
        .animation(.spring(duration: 0.2), value: canSend)
    }

    private func sendText() {
        let text = inputText
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        inputText = ""
        fieldFocus.wrappedValue = false
        Task { await viewModel.sendMessage(text) }
    }

    private func startRecording() async {
        guard await viewModel.speechService.requestPermissions() else {
            viewModel.errorMessage = viewModel.speechService.errorMessage
                ?? "Microphone or speech recognition access was denied."
            return
        }
        do {
            try viewModel.speechService.startRecording()
        } catch {
            viewModel.errorMessage = "Could not start recording: \(error.localizedDescription)"
        }
    }
}

// MARK: - RecordingInputRow

private struct RecordingInputRow: View {
    @Environment(CalendarViewModel.self) private var viewModel
    @Binding var inputText: String
    @State private var pulseScale: CGFloat = 1.0
    @State private var pulseOpacity: Double = 1.0

    private var speech: SpeechService { viewModel.speechService }
    private var isPaused: Bool { speech.recordingState == .paused }
    private var hasTranscript: Bool { !speech.liveTranscript.isEmpty }

    var body: some View {
        VStack(spacing: 10) {

            // Live transcript preview + pulsing mic indicator
            HStack(alignment: .center, spacing: 10) {
                Text(transcriptPlaceholder)
                    .italic(!hasTranscript)
                    .foregroundStyle(hasTranscript ? .primary : .secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                    .background(Color(.tertiarySystemBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))

                // Ripple pulse — only visible while actively recording (not paused)
                if !isPaused {
                    ZStack {
                        Circle()
                            .fill(Color.red.opacity(0.35))
                            .frame(width: 44, height: 44)
                            .scaleEffect(pulseScale)
                            .opacity(pulseOpacity)

                        Image(systemName: "mic.fill")
                            .foregroundStyle(.red)
                            .font(.system(size: 18, weight: .medium))
                            .frame(width: 44, height: 44)
                            .background(Color(.tertiarySystemBackground))
                            .clipShape(Circle())
                    }
                    .onAppear {
                        withAnimation(.easeOut(duration: 1.0).repeatForever(autoreverses: false)) {
                            pulseScale   = 1.9
                            pulseOpacity = 0.0
                        }
                    }
                    .onDisappear {
                        pulseScale   = 1.0
                        pulseOpacity = 1.0
                    }
                }
            }

            // WhatsApp-style action row: Pause/Resume · Delete · Send
            HStack(spacing: 10) {

                // Pause / Resume
                Button {
                    if isPaused {
                        try? speech.resumeRecording()
                    } else {
                        speech.pauseRecording()
                    }
                } label: {
                    Label(
                        isPaused ? "Resume" : "Pause",
                        systemImage: isPaused ? "play.fill" : "pause.fill"
                    )
                    .font(.subheadline.weight(.medium))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(Color(.secondarySystemBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .foregroundStyle(.primary)
                }

                // Delete — discards recording without sending
                Button(role: .destructive) {
                    speech.cancelRecording()
                } label: {
                    Label("Delete", systemImage: "trash")
                        .font(.subheadline.weight(.medium))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(Color(.secondarySystemBackground))
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                }

                // Send — finalises recording and routes transcript through the LLM
                Button {
                    Task { await viewModel.sendVoiceInput() }
                } label: {
                    Label("Send", systemImage: "arrow.up")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .foregroundStyle(.white)
                        .background(hasTranscript ? Color.accentColor : Color.secondary)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                .disabled(!hasTranscript)
            }
        }
    }

    private var transcriptPlaceholder: String {
        if hasTranscript { return speech.liveTranscript }
        return isPaused ? "Paused — tap Resume to continue" : "Listening…"
    }
}

// MARK: - ModelUnavailableBanner

private struct ModelUnavailableBanner: View {
    let message: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .imageScale(.medium)
            Text(message)
                .font(.footnote)
                .fixedSize(horizontal: false, vertical: true)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange)
    }
}

// MARK: - Preview

#Preview {
    ContentView()
        .environment(CalendarViewModel())
}
