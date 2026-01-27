import AVFoundation
import MLX
import SwiftUI
import KokoroSwift
import Combine
import MLXUtilsLibrary

/// The view model that manages text-to-speech functionality using the Kokoro TTS engine.
/// - Loading and managing the Kokoro TTS model
/// - Managing available voice options
/// - Audio playback using AVAudioEngine
/// - Converting text to speech audio
final class TestAppModel: ObservableObject {
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

  /// Current playback position in seconds
  @Published var currentTime: Double = 0.0

  /// Total duration of loaded audio in seconds
  @Published var totalDuration: Double = 0.0

  /// Stored audio samples for seeking
  private var audioSamples: [Float] = []

  /// Stored tokens for follow-along display
  private var allTokens: [(text: String, start_ts: Double?, end_ts: Double?, whitespace: String)] = []

  /// Audio format for playback
  private var audioFormat: AVAudioFormat?

  /// Timer for updating playback position
  var timer: Timer?

  /// Position tracking for seek operations
  private var playbackStartTime: Date?
  private var playbackStartPosition: Double = 0.0

  /// Gets the rating for a specific voice (0 if not rated)
  func rating(for voice: String) -> Int {
    voiceRatings[voice] ?? 0
  }

  /// Sets the rating for a specific voice (1-5, or 0 to clear)
  func setRating(_ rating: Int, for voice: String) {
    voiceRatings[voice] = rating
  }

  // MARK: - Playback Controls

  /// Pauses playback
  func pause() {
    guard isPlaying else { return }
    playerNode.pause()
    isPlaying = false
    // Save current position
    if let startTime = playbackStartTime {
      playbackStartPosition += Date().timeIntervalSince(startTime)
    }
    playbackStartTime = nil
  }

  /// Resumes playback from current position
  func resume() {
    guard hasAudio, !isPlaying else { return }
    // Use seek to reschedule the buffer from current position
    seek(to: currentTime)
  }

  /// Toggles between play and pause
  func togglePlayPause() {
    if isPlaying {
      pause()
    } else {
      resume()
    }
  }

  /// Stops playback and resets to beginning
  func stop() {
    timer?.invalidate()
    timer = nil
    playerNode.stop()
    isPlaying = false
    currentTime = 0.0
    playbackStartPosition = 0.0
    playbackStartTime = nil
    stringToFollowTheAudio = ""
  }

  /// Plays from the beginning
  func playFromStart() {
    seek(to: 0)
  }

  /// Seeks to a specific position in seconds
  func seek(to time: Double) {
    guard hasAudio, !audioSamples.isEmpty, let format = audioFormat else { return }

    let sampleRate = format.sampleRate
    let targetSample = Int(time * sampleRate)
    let clampedSample = max(0, min(targetSample, audioSamples.count))

    // Stop current playback
    playerNode.stop()
    timer?.invalidate()

    // Create buffer from the seek position
    let remainingSamples = Array(audioSamples[clampedSample...])
    guard let buffer = createBuffer(from: remainingSamples, format: format) else { return }

    // Schedule and play
    playerNode.scheduleBuffer(buffer, at: nil, options: .interrupts, completionHandler: nil)
    playerNode.play()

    // Update state
    currentTime = Double(clampedSample) / sampleRate
    playbackStartPosition = currentTime
    playbackStartTime = Date()
    isPlaying = true

    // Restart the timer for follow-along and position updates
    startPlaybackTimer()
  }

  /// Starts the timer that updates playback position and follow-along text
  private func startPlaybackTimer() {
    timer?.invalidate()

    timer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] timer in
      guard let self else {
        timer.invalidate()
        return
      }

      // Update current time based on actual elapsed time
      if self.isPlaying, let startTime = self.playbackStartTime {
        self.currentTime = self.playbackStartPosition + Date().timeIntervalSince(startTime)
      }

      // Check if playback finished
      if self.currentTime >= self.totalDuration {
        self.currentTime = self.totalDuration
        self.isPlaying = false
        self.playbackStartTime = nil
        timer.invalidate()
        return
      }

      // Update follow-along text
      self.updateFollowAlongText()
    }
  }

  /// Updates the follow-along text based on current playback position
  private func updateFollowAlongText() {
    var text = ""
    for token in allTokens {
      if let start = token.start_ts, start <= currentTime {
        text += token.text + (token.whitespace.isEmpty ? "" : " ")
      }
    }
    stringToFollowTheAudio = text
  }

  /// Initializes the test app model with TTS engine, audio components, and voice data.
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

    // Configure audio session for iOS
    #if os(iOS)
      do {
        let audioSession = AVAudioSession.sharedInstance()
        try audioSession.setCategory(.playback, mode: .default)
        try audioSession.setActive(true)
      } catch {
        logPrint("Failed to set up AVAudioSession: \(error.localizedDescription)")
      }
    #endif
  }

  /// Splits text into chunks of sentences for processing within token limits.
  /// - Parameters:
  ///   - text: The text to split
  ///   - sentencesPerChunk: Maximum number of sentences per chunk
  /// - Returns: Array of text chunks
  private func splitIntoChunks(_ text: String, sentencesPerChunk: Int = 3) -> [String] {
    // Remove newlines and replace with spaces
    let cleanedText = text.replacingOccurrences(of: "\n", with: " ")
      .replacingOccurrences(of: "\r", with: " ")

    // Split on sentence-ending punctuation while keeping the punctuation
    let pattern = "(?<=[.!?])\\s+"
    let regex = try! NSRegularExpression(pattern: pattern)
    let range = NSRange(cleanedText.startIndex..., in: cleanedText)

    var sentences: [String] = []
    var lastEnd = cleanedText.startIndex

    regex.enumerateMatches(in: cleanedText, range: range) { match, _, _ in
      if let match = match {
        let matchRange = Range(match.range, in: cleanedText)!
        let sentence = String(cleanedText[lastEnd..<matchRange.lowerBound])
        sentences.append(sentence.trimmingCharacters(in: .whitespaces))
        lastEnd = matchRange.upperBound
      }
    }

    // Add any remaining text as the last sentence
    let remaining = String(cleanedText[lastEnd...]).trimmingCharacters(in: .whitespaces)
    if !remaining.isEmpty {
      sentences.append(remaining)
    }

    // Group sentences into chunks
    var chunks: [String] = []
    for i in stride(from: 0, to: sentences.count, by: sentencesPerChunk) {
      let end = min(i + sentencesPerChunk, sentences.count)
      let chunk = sentences[i..<end].joined(separator: " ")
      chunks.append(chunk)
    }

    return chunks.isEmpty ? [cleanedText] : chunks
  }

  /// Creates an audio buffer from audio samples.
  /// - Parameters:
  ///   - audio: Array of audio samples
  ///   - format: The audio format to use
  /// - Returns: An AVAudioPCMBuffer or nil if creation fails
  private func createBuffer(from audio: [Float], format: AVAudioFormat) -> AVAudioPCMBuffer? {
    guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(audio.count)) else {
      print("Couldn't create buffer")
      return nil
    }

    buffer.frameLength = buffer.frameCapacity
    let channels = buffer.floatChannelData!
    let dst: UnsafeMutablePointer<Float> = channels[0]

    audio.withUnsafeBufferPointer { buf in
      precondition(buf.baseAddress != nil)
      let byteCount = buf.count * MemoryLayout<Float>.stride
      UnsafeMutableRawPointer(dst)
        .copyMemory(from: UnsafeRawPointer(buf.baseAddress!), byteCount: byteCount)
    }

    return buffer
  }

  /// Converts the provided text to speech and plays it through the audio engine.
  /// Text is split into chunks to work around token limits.
  /// - Parameter text: The text to be converted to speech
  func say(_ text: String) {
    // Stop any existing playback
    stop()

    let chunks = splitIntoChunks(text, sentencesPerChunk: 3)
    print("Split text into \(chunks.count) chunk(s)")

    let sampleRate = Double(KokoroTTS.Constants.samplingRate)
    let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
    audioFormat = format

    // Connect the player node to the audio engine's mixer
    audioEngine.connect(playerNode, to: audioEngine.mainMixerNode, format: format)

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
    var totalAudioLength: Double = 0.0

    // Process each chunk and schedule buffers sequentially
    for (index, chunk) in chunks.enumerated() {
      print("Processing chunk \(index + 1)/\(chunks.count): \"\(chunk.prefix(50))...\"")

      // Generate audio using the selected voice
      let (audio, tokenArray) = try! kokoroTTSEngine.generateAudio(
        voice: voices[selectedVoice + ".npy"]!,
        language: selectedVoice.first! == "a" ? .enUS : .enGB,
        text: chunk,
        speed: speechSpeed
      )

      // Store audio samples for seeking
      audioSamples.append(contentsOf: audio)

      // Adjust token timestamps based on accumulated audio length
      if let tokenArray {
        for token in tokenArray {
          let adjustedStart = token.start_ts.map { $0 + totalAudioLength }
          let adjustedEnd = token.end_ts.map { $0 + totalAudioLength }
          allTokens.append((text: token.text, start_ts: adjustedStart, end_ts: adjustedEnd, whitespace: token.whitespace))
          print("\(token.text): \(adjustedStart, default: "UNK") - \(adjustedEnd, default: "UNK")")
        }
      }

      let chunkAudioLength = Double(audio.count) / sampleRate
      totalAudioLength += chunkAudioLength

      print("Chunk \(index + 1) audio length: " + String(format: "%.4f", chunkAudioLength))

      // Create and schedule the buffer
      guard let buffer = createBuffer(from: audio, format: format) else {
        continue
      }

      // First chunk interrupts any playing audio, subsequent chunks are queued
      let options: AVAudioPlayerNodeBufferOptions = index == 0 ? .interrupts : []
      playerNode.scheduleBuffer(buffer, at: nil, options: options, completionHandler: nil)

      // Start playback immediately after first chunk is scheduled
      if index == 0 {
        playerNode.play()
        isPlaying = true
        playbackStartTime = Date()
        playbackStartPosition = 0.0
      }
    }

    // Update state
    totalDuration = totalAudioLength
    hasAudio = true
    currentTime = 0.0
    stringToFollowTheAudio = ""

    print("Total audio length: " + String(format: "%.4f", totalAudioLength))

    // Start the playback timer
    startPlaybackTimer()
  }
}
