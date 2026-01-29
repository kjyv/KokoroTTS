import Foundation
import MediaPlayer

// MARK: - Media Controls

extension KokoroTTSModel {
  /// Sets up the remote command center to handle media keys (play/pause).
  func setupRemoteCommandCenter() {
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

    // Previous track command (seek to beginning)
    commandCenter.previousTrackCommand.isEnabled = true
    commandCenter.previousTrackCommand.addTarget { [weak self] _ in
      guard let self, self.hasAudio else { return .commandFailed }
      DispatchQueue.main.async {
        self.pause()
        self.seek(to: 0)
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
  func updateNowPlayingInfo() {
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
  func displayNameForVoice(_ voice: String) -> String {
    if let underscoreIndex = voice.firstIndex(of: "_") {
      let nameStart = voice.index(after: underscoreIndex)
      let name = String(voice[nameStart...])
      return name.prefix(1).uppercased() + name.dropFirst()
    }
    return voice
  }
}
