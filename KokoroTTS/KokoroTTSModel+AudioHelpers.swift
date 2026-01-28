import AVFoundation
import Foundation

// MARK: - Audio Helpers

extension KokoroTTSModel {
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

  /// Creates an audio buffer from audio samples.
  /// - Parameters:
  ///   - audio: Array of audio samples
  ///   - format: The audio format to use
  /// - Returns: An AVAudioPCMBuffer or nil if creation fails
  func createBuffer(from audio: [Float], format: AVAudioFormat) -> AVAudioPCMBuffer? {
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
}
