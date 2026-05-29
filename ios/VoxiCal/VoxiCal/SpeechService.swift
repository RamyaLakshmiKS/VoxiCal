import Speech
import AVFoundation

// MARK: - RecordingState

enum RecordingState: Equatable {
    case idle
    case recording
    case paused
}

// MARK: - SpeechService

/// Manages voice recording and real-time transcription using SFSpeechRecognizer.
/// Implements a WhatsApp-style recording UX with Pause/Delete/Send controls.
@MainActor
@Observable
class SpeechService {

    // MARK: - Observed State (drives UI)

    var liveTranscript: String = ""
    var recordingState: RecordingState = .idle
    var errorMessage: String? = nil

    // MARK: - Private

    private var audioEngine = AVAudioEngine()
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private let speechRecognizer = SFSpeechRecognizer(locale: .current)

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
    func startRecording() throws {
        guard recordingState == .idle else { return }

        // Configure audio session for recording only
        let audioSession = AVAudioSession.sharedInstance()
        try audioSession.setCategory(.record, mode: .measurement, options: .duckOthers)
        try audioSession.setActive(true, options: .notifyOthersOnDeactivation)

        // Cancel any prior recognition task
        recognitionTask?.cancel()
        recognitionTask = nil

        // Fresh audio engine and request
        audioEngine = AVAudioEngine()
        recognitionRequest = SFSpeechAudioBufferRecognitionRequest()

        guard let recognitionRequest else { return }

        // Install the tap BEFORE starting the engine so the first buffer is non-zero.
        // Starting the engine first causes AVAudioBuffer to deliver empty frames.
        let inputNode = audioEngine.inputNode
        inputNode.installTap(
            onBus: 0,
            bufferSize: 1024,
            format: inputNode.outputFormat(forBus: 0)
        ) { buffer, _ in
            recognitionRequest.append(buffer)
        }

        try audioEngine.start()

        liveTranscript = ""
        errorMessage = nil
        recordingState = .recording

        // Start recognition task
        recognitionTask = speechRecognizer?.recognitionTask(with: recognitionRequest) { [weak self] result, error in
            Task { @MainActor in
                guard let self else { return }

                if let result = result {
                    self.liveTranscript = result.bestTranscription.formattedString
                }

                // Only surface unexpected errors (suppress expected ones like task cancellation)
                if let error = error, !Task.isCancelled {
                    let errorDesc = error.localizedDescription.lowercased()
                    if !errorDesc.contains("cancelled") && !errorDesc.contains("recognitiontask") {
                        self.errorMessage = "Transcription error: \(error.localizedDescription)"
                    }
                }

                if error != nil {
                    self.recordingState = .idle
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
        // Stop audio engine
        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)

        // Cancel recognition
        recognitionTask?.cancel()
        recognitionTask = nil
        recognitionRequest = nil

        // Release the audio session
        try? AVAudioSession.sharedInstance().setActive(
            false,
            options: .notifyOthersOnDeactivation
        )
    }
}
