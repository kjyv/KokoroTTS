import AVFoundation
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

  /// Whether audio generation is still in progress
  @Published var isGeneratingAudio: Bool = false

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
    updateNowPlayingInfo()
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
    updateNowPlayingInfo()
  }

  /// Plays from the beginning
  func playFromStart() {
    seek(to: 0)
  }

  /// Saves the current audio to a file.
  /// - Parameter url: The destination URL for the audio file
  /// - Throws: An error if saving fails
  func saveAudio(to url: URL) throws {
    guard !audioSamples.isEmpty, let format = audioFormat else {
      throw NSError(domain: "KokoroTTS", code: 1, userInfo: [NSLocalizedDescriptionKey: "No audio to save"])
    }

    // Create the audio file
    let audioFile = try AVAudioFile(
      forWriting: url,
      settings: format.settings,
      commonFormat: .pcmFormatFloat32,
      interleaved: false
    )

    // Create a buffer with all the samples
    guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(audioSamples.count)) else {
      throw NSError(domain: "KokoroTTS", code: 2, userInfo: [NSLocalizedDescriptionKey: "Failed to create audio buffer"])
    }

    buffer.frameLength = buffer.frameCapacity
    let channelData = buffer.floatChannelData![0]
    for (index, sample) in audioSamples.enumerated() {
      channelData[index] = sample
    }

    // Write the buffer to the file
    try audioFile.write(from: buffer)
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

    // Update Now Playing info for media keys
    updateNowPlayingInfo()

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
        self.updateNowPlayingInfo()
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

    // Warm up the model with a short text to trigger MLX compilation
    warmUpModel()

    // Set up media key controls (play/pause on keyboard)
    setupRemoteCommandCenter()

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

  /// Sets up the remote command center to handle media keys (play/pause).
  private func setupRemoteCommandCenter() {
    let commandCenter = MPRemoteCommandCenter.shared()

    // Play command
    commandCenter.playCommand.isEnabled = true
    commandCenter.playCommand.addTarget { [weak self] _ in
      guard let self, self.hasAudio else { return .commandFailed }
      DispatchQueue.main.async {
        self.resume()
      }
      return .success
    }

    // Pause command
    commandCenter.pauseCommand.isEnabled = true
    commandCenter.pauseCommand.addTarget { [weak self] _ in
      guard let self else { return .commandFailed }
      DispatchQueue.main.async {
        self.pause()
      }
      return .success
    }

    // Toggle play/pause command
    commandCenter.togglePlayPauseCommand.isEnabled = true
    commandCenter.togglePlayPauseCommand.addTarget { [weak self] _ in
      guard let self else { return .commandFailed }
      DispatchQueue.main.async {
        self.togglePlayPause()
      }
      return .success
    }

    // Skip forward/backward (optional - seek 10 seconds)
    commandCenter.skipForwardCommand.isEnabled = true
    commandCenter.skipForwardCommand.preferredIntervals = [10]
    commandCenter.skipForwardCommand.addTarget { [weak self] _ in
      guard let self, self.hasAudio else { return .commandFailed }
      DispatchQueue.main.async {
        self.seek(to: min(self.currentTime + 10, self.totalDuration))
      }
      return .success
    }

    commandCenter.skipBackwardCommand.isEnabled = true
    commandCenter.skipBackwardCommand.preferredIntervals = [10]
    commandCenter.skipBackwardCommand.addTarget { [weak self] _ in
      guard let self, self.hasAudio else { return .commandFailed }
      DispatchQueue.main.async {
        self.seek(to: max(self.currentTime - 10, 0))
      }
      return .success
    }

    // Change playback position (for scrubbing)
    commandCenter.changePlaybackPositionCommand.isEnabled = true
    commandCenter.changePlaybackPositionCommand.addTarget { [weak self] event in
      guard let self,
            let positionEvent = event as? MPChangePlaybackPositionCommandEvent else {
        return .commandFailed
      }
      DispatchQueue.main.async {
        self.seek(to: positionEvent.positionTime)
      }
      return .success
    }
  }

  /// Updates the Now Playing info center with current playback information.
  private func updateNowPlayingInfo() {
    let infoCenter = MPNowPlayingInfoCenter.default()

    // Set playback state to tell the system we're the active media app
    if isPlaying {
      infoCenter.playbackState = .playing
    } else if hasAudio {
      infoCenter.playbackState = .paused
    } else {
      infoCenter.playbackState = .stopped
    }

    var nowPlayingInfo = [String: Any]()

    nowPlayingInfo[MPMediaItemPropertyTitle] = "Kokoro TTS"
    nowPlayingInfo[MPMediaItemPropertyArtist] = displayNameForVoice(selectedVoice)
    nowPlayingInfo[MPNowPlayingInfoPropertyElapsedPlaybackTime] = currentTime
    nowPlayingInfo[MPMediaItemPropertyPlaybackDuration] = totalDuration
    nowPlayingInfo[MPNowPlayingInfoPropertyPlaybackRate] = isPlaying ? 1.0 : 0.0

    infoCenter.nowPlayingInfo = nowPlayingInfo
  }

  /// Returns the display name for a voice (e.g., "af_bella" -> "Bella").
  private func displayNameForVoice(_ voice: String) -> String {
    if let underscoreIndex = voice.firstIndex(of: "_") {
      let nameStart = voice.index(after: underscoreIndex)
      let name = String(voice[nameStart...])
      return name.prefix(1).uppercased() + name.dropFirst()
    }
    return voice
  }

  /// Splits text into chunks of sentences for processing within token limits.
  /// Also splits on headlines (lines followed by empty lines).
  /// - Parameters:
  ///   - text: The text to split
  ///   - sentencesPerChunk: Maximum number of sentences per chunk
  /// - Returns: Array of text chunks
  private func splitIntoChunks(_ text: String, sentencesPerChunk: Int = 2) -> [String] {
    // First, split on headlines (line followed by empty line)
    // This regex matches: non-empty line, then one or more empty lines
    let paragraphs = text.components(separatedBy: .newlines)

    var sections: [String] = []
    var currentSection: [String] = []
    var previousLineEmpty = false

    for line in paragraphs {
      let trimmedLine = line.trimmingCharacters(in: .whitespaces)

      if trimmedLine.isEmpty {
        // Empty line - if we have content, check if previous was a headline
        if !currentSection.isEmpty {
          // If we only have one line before empty line, it's likely a headline - make it its own chunk
          if currentSection.count == 1 && !previousLineEmpty {
            sections.append(currentSection[0])
            currentSection = []
          }
        }
        previousLineEmpty = true
      } else {
        // Non-empty line
        if previousLineEmpty && !currentSection.isEmpty {
          // We had content, then empty line(s), now new content - start new section
          sections.append(currentSection.joined(separator: " "))
          currentSection = []
        }
        currentSection.append(trimmedLine)
        previousLineEmpty = false
      }
    }

    // Add remaining content
    if !currentSection.isEmpty {
      sections.append(currentSection.joined(separator: " "))
    }

    // Now split each section into sentences and group into chunks
    var chunks: [String] = []

    for section in sections {
      // Split on sentence-ending punctuation while keeping the punctuation
      // Also handles sentences ending with ." or ." (period inside quotes)
      let pattern = "(?<=[.!?][\"\u{201C}\u{201D}]?)\\s+"
      let regex = try! NSRegularExpression(pattern: pattern)
      let range = NSRange(section.startIndex..., in: section)

      var sentences: [String] = []
      var lastEnd = section.startIndex

      regex.enumerateMatches(in: section, range: range) { match, _, _ in
        if let match = match {
          let matchRange = Range(match.range, in: section)!
          let sentence = String(section[lastEnd..<matchRange.lowerBound])
          let trimmed = sentence.trimmingCharacters(in: .whitespaces)
          if !trimmed.isEmpty {
            sentences.append(trimmed)
          }
          lastEnd = matchRange.upperBound
        }
      }

      // Add any remaining text as the last sentence
      let remaining = String(section[lastEnd...]).trimmingCharacters(in: .whitespaces)
      if !remaining.isEmpty {
        sentences.append(remaining)
      }

      // Group sentences into chunks
      for i in stride(from: 0, to: sentences.count, by: sentencesPerChunk) {
        let end = min(i + sentencesPerChunk, sentences.count)
        let chunk = sentences[i..<end].joined(separator: " ")
        if !chunk.isEmpty {
          chunks.append(chunk)
        }
      }
    }

    return chunks.isEmpty ? [text.replacingOccurrences(of: "\n", with: " ")] : chunks
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

    // Mark as generating
    isGeneratingAudio = true

    let chunks = splitIntoChunks(text, sentencesPerChunk: 2)
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
