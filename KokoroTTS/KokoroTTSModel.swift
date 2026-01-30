import AVFoundation
import AudioToolbox
import MLX
import SwiftUI
import KokoroSwift
import Combine
import MLXUtilsLibrary
import MediaPlayer

/// The view model that manages text-to-speech functionality using the Kokoro TTS engine.
/// - Loading and managing the Kokoro TTS model
/// - Managing available voice options
/// - Audio playback using AVAudioEngine
/// - Converting text to speech audio
final class KokoroTTSModel: ObservableObject {
  /// UserDefaults key for storing the selected voice preference
  private static let selectedVoiceKey = "selectedVoice"
  /// UserDefaults key for storing voice ratings
  private static let voiceRatingsKey = "voiceRatings"
  /// UserDefaults key for storing speech speed
  private static let speechSpeedKey = "speechSpeed"

  /// The Kokoro text-to-speech engine instance
  let kokoroTTSEngine: KokoroTTS!

  /// The audio engine used for playback
  let audioEngine: AVAudioEngine!

  /// The audio player node attached to the audio engine
  let playerNode: AVAudioPlayerNode!

  /// Dictionary of available voices, mapped by voice name to MLX array data
  let voices: [String: MLXArray]

  /// Array of voice names available for selection in the UI
  @Published var voiceNames: [String] = []

  /// The text input from the user (shared with UI and Services)
  @Published var inputText: String = ""

  /// The currently selected voice name
  @Published var selectedVoice: String = "" {
    didSet {
      UserDefaults.standard.set(selectedVoice, forKey: Self.selectedVoiceKey)
    }
  }

  @Published var stringToFollowTheAudio: String = ""

  /// Voice ratings (1-5 stars) keyed by voice name
  @Published var voiceRatings: [String: Int] = [:] {
    didSet {
      UserDefaults.standard.set(voiceRatings, forKey: Self.voiceRatingsKey)
    }
  }

  /// Speech speed multiplier (0.5 = half speed, 1.0 = normal, 2.0 = double speed)
  @Published var speechSpeed: Float = 1.0 {
    didSet {
      UserDefaults.standard.set(speechSpeed, forKey: Self.speechSpeedKey)
    }
  }

  // MARK: - Playback State

  /// Whether audio is currently playing
  @Published var isPlaying: Bool = false

  /// Whether there is audio loaded and ready to play
  @Published var hasAudio: Bool = false

  /// Whether audio generation is still in progress
  @Published var isGeneratingAudio: Bool = false

  /// Flag to cancel ongoing generation
  var shouldCancelGeneration: Bool = false

  /// Current playback position in seconds
  @Published var currentTime: Double = 0.0

  /// Total duration of loaded audio in seconds
  @Published var totalDuration: Double = 0.0

  /// Stored audio samples for seeking
  var audioSamples: [Float] = []

  /// Stored tokens for follow-along display
  var allTokens: [(text: String, start_ts: Double?, end_ts: Double?, whitespace: String)] = []

  /// Index of the token currently being spoken (-1 if none)
  @Published var currentTokenIndex: Int = -1

  /// Audio format for playback
  var audioFormat: AVAudioFormat?

  /// Timer for updating playback position
  var timer: Timer?

  /// Position tracking for seek operations
  var playbackStartTime: Date?
  var playbackStartPosition: Double = 0.0

  /// Gets the rating for a specific voice (0 if not rated)
  func rating(for voice: String) -> Int {
    voiceRatings[voice] ?? 0
  }

  /// Sets the rating for a specific voice (1-5, or 0 to clear)
  func setRating(_ rating: Int, for voice: String) {
    voiceRatings[voice] = rating
  }

  /// Initializes the TTS model with TTS engine, audio components, and voice data.
  init() {
    // Load the Kokoro TTS model from the app bundle
    let modelPath = Bundle.main.url(forResource: "kokoro-v1_0", withExtension: "safetensors")!
    kokoroTTSEngine = KokoroTTS(modelPath: modelPath)

    // Initialize audio engine and player node
    audioEngine = AVAudioEngine()
    playerNode = AVAudioPlayerNode()
    audioEngine.attach(playerNode)

    // Load voice data from NPZ file
    let voiceFilePath = Bundle.main.url(forResource: "voices", withExtension: "npz")!
    voices = NpyzReader.read(fileFromPath: voiceFilePath) ?? [:]

    // Extract voice names and sort them alphabetically
    voiceNames = voices.keys.map { String($0.split(separator: ".")[0]) }.sorted(by: <)

    // Load saved voice preference, or default to first voice
    if let savedVoice = UserDefaults.standard.string(forKey: Self.selectedVoiceKey),
       voiceNames.contains(savedVoice) {
      selectedVoice = savedVoice
    } else {
      selectedVoice = voiceNames[0]
    }

    // Load saved voice ratings
    if let savedRatings = UserDefaults.standard.dictionary(forKey: Self.voiceRatingsKey) as? [String: Int] {
      voiceRatings = savedRatings
    }

    // Load saved speech speed
    let savedSpeed = UserDefaults.standard.float(forKey: Self.speechSpeedKey)
    if savedSpeed > 0 {
      speechSpeed = savedSpeed
    }

    // Warm up the model with a short text to trigger MLX compilation
    warmUpModel()

    // Set up media key controls (play/pause on keyboard)
    setupRemoteCommandCenter()
  }

  /// Warms up the TTS model by running a short inference.
  /// This triggers MLX lazy compilation so the first real generation is fast.
  private func warmUpModel() {
    DispatchQueue.global(qos: .userInitiated).async { [self] in
      print("Warming up TTS model...")
      let startTime = Date()

      // Run a minimal inference to trigger compilation
      let _ = try? kokoroTTSEngine.generateAudio(
        voice: voices[selectedVoice + ".npy"]!,
        language: selectedVoice.first == "a" ? .enUS : .enGB,
        text: "Hello",
        speed: 1.0
      )

      let elapsed = Date().timeIntervalSince(startTime)
      print("Model warm-up complete in \(String(format: "%.2f", elapsed))s")
    }
  }

  /// Converts the provided text to speech and plays it through the audio engine.
  /// Text is split into chunks to work around token limits.
  /// - Parameter text: The text to be converted to speech
  func say(_ text: String) {
    // Stop any existing playback
    stop()

    // Mark as generating and reset cancel flag
    isGeneratingAudio = true
    shouldCancelGeneration = false

    // Preprocess text to improve speech output
    var processedText = text
    processedText = removeHyphensFromCompoundWords(processedText)
    processedText = convertParentheticalsToDashes(processedText)
    processedText = convertSlashesToDashes(processedText)
    let chunks = splitIntoChunks(processedText, sentencesPerChunk: 2)
    print("Split text into \(chunks.count) chunk(s)")

    let sampleRate = Double(KokoroTTS.Constants.samplingRate)
    let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
    audioFormat = format

    // Connect the player node to the audio engine's mixer
    audioEngine.connect(playerNode, to: audioEngine.mainMixerNode, format: format)

    // Request a larger buffer size to reduce audio overload warnings during heavy CPU load
    let outputUnit = audioEngine.outputNode.audioUnit!
    var bufferSize: UInt32 = 2048
    AudioUnitSetProperty(
      outputUnit,
      kAudioDevicePropertyBufferFrameSize,
      kAudioUnitScope_Global,
      0,
      &bufferSize,
      UInt32(MemoryLayout<UInt32>.size)
    )

    // Start the audio engine
    do {
      try audioEngine.start()
    } catch {
      print("Audio engine failed to start: \(error.localizedDescription)")
      return
    }

    // Reset stored data
    audioSamples = []
    allTokens = []

    // Show player UI immediately
    hasAudio = true
    currentTime = 0.0
    totalDuration = 0.0
    stringToFollowTheAudio = ""

    // Capture values needed for background processing
    let voice = voices[selectedVoice + ".npy"]!
    let language: Language = selectedVoice.first == "a" ? .enUS : .enGB
    let speed = speechSpeed

    // Process chunks in background to keep UI responsive
    DispatchQueue.global(qos: .userInitiated).async { [weak self] in
      guard let self else { return }

      var totalAudioLength: Double = 0.0

      for (index, chunk) in chunks.enumerated() {
        // Check if generation was cancelled
        if self.shouldCancelGeneration {
          print("Generation cancelled")
          break
        }

        print("Processing chunk \(index + 1)/\(chunks.count): \"\(chunk.prefix(50))...\"")

        // Generate audio using the selected voice
        guard let (audio, tokenArray) = try? self.kokoroTTSEngine.generateAudio(
          voice: voice,
          language: language,
          text: chunk,
          speed: speed
        ) else {
          print("Failed to generate audio for chunk \(index + 1)")
          continue
        }

        let chunkAudioLength = Double(audio.count) / sampleRate
        let currentTotalLength = totalAudioLength

        // Update state on main thread
        DispatchQueue.main.async {
          // Store audio samples for seeking
          self.audioSamples.append(contentsOf: audio)

          // Adjust token timestamps based on accumulated audio length
          if let tokenArray {
            // Add space between chunks (not before the first chunk)
            if index > 0 && !self.allTokens.isEmpty {
              self.allTokens.append((text: " ", start_ts: currentTotalLength, end_ts: currentTotalLength, whitespace: ""))
            }
            for token in tokenArray {
              let adjustedStart = token.start_ts.map { $0 + currentTotalLength }
              let adjustedEnd = token.end_ts.map { $0 + currentTotalLength }
              self.allTokens.append((text: token.text, start_ts: adjustedStart, end_ts: adjustedEnd, whitespace: token.whitespace))
            }
          }

          // Create and schedule the buffer
          guard let buffer = self.createBuffer(from: audio, format: format) else { return }

          // First chunk interrupts any playing audio, subsequent chunks are queued
          let options: AVAudioPlayerNodeBufferOptions = index == 0 ? .interrupts : []
          self.playerNode.scheduleBuffer(buffer, at: nil, options: options, completionHandler: nil)

          // Start playback immediately after first chunk is scheduled
          if index == 0 {
            self.playerNode.play()
            self.isPlaying = true
            self.playbackStartTime = Date()
            self.playbackStartPosition = 0.0
            self.startPlaybackTimer()
          }

          // Update duration as we process chunks
          self.totalDuration = currentTotalLength + chunkAudioLength
          self.updateNowPlayingInfo()
        }

        totalAudioLength += chunkAudioLength
        print("Chunk \(index + 1) audio length: " + String(format: "%.4f", chunkAudioLength))
      }

      print("Total audio length: " + String(format: "%.4f", totalAudioLength))

      // Mark generation as complete
      DispatchQueue.main.async {
        self.isGeneratingAudio = false
      }
    }
  }
}
