import Speech
import AVFoundation

// MARK: - RecordingState

enum RecordingState: Equatable {
    case idle
    case recording
    case paused
}

// MARK: - SpeechService

/// Manages voice recording and real-time transcription using iOS 26's SpeechAnalyzer.
///
/// Implements a WhatsApp-style recording UX:
///   Idle  →  tap mic  →  Recording  →  tap Pause / Delete / Send
///   Paused  →  tap Resume or Send
///
/// SpeechAnalyzer runs fully on-device (no server, no rate limit, no 1-minute cap).
@MainActor
@Observable
class SpeechService {

    // MARK: - Observed State (drives UI)

    var liveTranscript: String = ""
    var recordingState: RecordingState = .idle
    var errorMessage: String? = nil

    // MARK: - Private

    private var audioEngine = AVAudioEngine()
    private var analyzer: SpeechAnalyzer?
    private var transcriber: SpeechTranscriber?
    private var streamTask: Task<Void, Never>?

    // MARK: - Permissions

    /// Requests microphone and speech recognition permissions.
    /// Returns true only when both are granted.
    func requestPermissions() async -> Bool {
        // Microphone — iOS 17+ async API
        guard await AVAudioApplication.requestRecordPermission() else {
            errorMessage = "Microphone access is required. Enable it in Settings → Privacy & Security → Microphone."
            return false
        }

        // Speech recognition
        let speechGranted: Bool = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status == .authorized)
            }
        }

        if !speechGranted {
            errorMessage = "Speech recognition is required. Enable it in Settings → Privacy & Security → Speech Recognition."
        }
        return speechGranted
    }

    // MARK: - Recording Controls

    /// Tap 1: Start a new recording session.
    func startRecording() async throws {
        guard recordingState == .idle else { return }

        // Configure audio session for recording only
        let audioSession = AVAudioSession.sharedInstance()
        try audioSession.setCategory(.record, mode: .measurement, options: .duckOthers)
        try audioSession.setActive(true, options: .notifyOthersOnDeactivation)

        // Fresh instances for each recording so there's no leftover state
        audioEngine = AVAudioEngine()
        let newTranscriber = SpeechTranscriber(locale: .current, preset: .dictation)
        transcriber = newTranscriber

        let newAnalyzer = SpeechAnalyzer(
            audioInput: audioEngine.inputNode,
            modules: [newTranscriber]
        )
        analyzer = newAnalyzer

        // Audio engine must start before the analyzer
        try audioEngine.start()
        try await newAnalyzer.start()

        liveTranscript = ""
        errorMessage = nil
        recordingState = .recording

        // Stream transcription results — task runs on main actor (inherited from @MainActor context)
        streamTask = Task { [weak self] in
            guard let self else { return }
            do {
                for try await result in newTranscriber.results {
                    self.liveTranscript = result.bestTranscription.formattedString
                }
            } catch {
                // Stream ends naturally when recording stops; only surface unexpected errors
                if !Task.isCancelled {
                    self.errorMessage = "Transcription error: \(error.localizedDescription)"
                }
            }
        }
    }

    /// Pause button: freeze the live transcript without discarding it.
    func pauseRecording() {
        guard recordingState == .recording else { return }
        audioEngine.pause()
        recordingState = .paused
    }

    /// Resume button: continue from the current transcript.
    func resumeRecording() throws {
        guard recordingState == .paused else { return }
        try audioEngine.start()
        recordingState = .recording
    }

    /// Delete button: discard the current recording entirely and return to idle.
    func cancelRecording() {
        teardown()
        liveTranscript = ""
        recordingState = .idle
    }

    /// Send button: stop recording and return the final transcript for the LLM.
    func stopAndSend() -> String {
        let finalText = liveTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
        teardown()
        liveTranscript = ""
        recordingState = .idle
        return finalText
    }

    // MARK: - Private Teardown

    private func teardown() {
        // Cancel the result-streaming task first so it doesn't race with engine stop
        streamTask?.cancel()
        streamTask = nil

        // Stop audio — this naturally ends the analyzer's input stream
        audioEngine.stop()

        analyzer = nil
        transcriber = nil

        // Release the audio session so other apps (e.g. Music) can resume
        try? AVAudioSession.sharedInstance().setActive(
            false,
            options: .notifyOthersOnDeactivation
        )
    }
}
