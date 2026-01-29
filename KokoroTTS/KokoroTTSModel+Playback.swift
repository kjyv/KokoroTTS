import AVFoundation
import Foundation

// MARK: - Playback Controls

extension KokoroTTSModel {
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

  /// Resumes playback from current position, or restarts if at the end
  func resume() {
    guard hasAudio, !isPlaying else { return }
    // If at the end, restart from beginning
    let position = currentTime >= totalDuration ? 0.0 : currentTime
    seek(to: position)
  }

  /// Toggles between play and pause
  func togglePlayPause() {
    if isPlaying {
      pause()
    } else {
      resume()
    }
  }

  /// Stops playback and resets to beginning, clearing audio so text is editable again
  func stop() {
    timer?.invalidate()
    timer = nil
    playerNode.stop()
    isPlaying = false
    hasAudio = false
    currentTime = 0.0
    totalDuration = 0.0
    playbackStartPosition = 0.0
    playbackStartTime = nil
    audioSamples = []
    allTokens = []
    stringToFollowTheAudio = ""
    currentTokenIndex = -1
    updateNowPlayingInfo()
  }

  /// Clears audio state without stopping the engine (used when text is edited)
  func clearAudio() {
    timer?.invalidate()
    timer = nil
    playerNode.stop()
    isPlaying = false
    hasAudio = false
    currentTime = 0.0
    totalDuration = 0.0
    playbackStartPosition = 0.0
    playbackStartTime = nil
    audioSamples = []
    allTokens = []
    stringToFollowTheAudio = ""
    currentTokenIndex = -1
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
  func startPlaybackTimer() {
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

      // Check if playback finished naturally
      if self.currentTime >= self.totalDuration && !self.isGeneratingAudio {
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

  /// Updates the follow-along text and current token index based on current playback position
  func updateFollowAlongText() {
    var text = ""
    var newTokenIndex = -1

    for (index, token) in allTokens.enumerated() {
      if let start = token.start_ts, start <= currentTime {
        text += token.text + (token.whitespace.isEmpty ? "" : " ")

        // Check if this is the currently active token
        if let end = token.end_ts, currentTime < end {
          newTokenIndex = index
        } else if let end = token.end_ts, currentTime >= end {
          // Past this token, check if there's a next one
          if index == allTokens.count - 1 {
            // Last token - keep it highlighted until playback ends
            newTokenIndex = index
          }
        }
      }
    }

    stringToFollowTheAudio = text
    currentTokenIndex = newTokenIndex
  }
}
