import AudioToolbox
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

    let fileExtension = url.pathExtension.lowercased()

    if fileExtension == "m4a" {
      try saveAsM4A(to: url, format: format)
    } else {
      try saveAsWAV(to: url, format: format)
    }
  }

  /// Saves the audio as a WAV file.
  private func saveAsWAV(to url: URL, format: AVAudioFormat) throws {
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

  /// Saves the audio as an M4A (AAC) file using ExtAudioFile for codec conversion.
  private func saveAsM4A(to url: URL, format: AVAudioFormat) throws {
    // Remove existing file if present
    try? FileManager.default.removeItem(at: url)

    // Define the output format (AAC)
    var outputFormat = AudioStreamBasicDescription(
      mSampleRate: format.sampleRate,
      mFormatID: kAudioFormatMPEG4AAC,
      mFormatFlags: 0,
      mBytesPerPacket: 0,
      mFramesPerPacket: 1024,
      mBytesPerFrame: 0,
      mChannelsPerFrame: 1,
      mBitsPerChannel: 0,
      mReserved: 0
    )

    // Create the output file
    var extAudioFile: ExtAudioFileRef?
    var status = ExtAudioFileCreateWithURL(
      url as CFURL,
      kAudioFileM4AType,
      &outputFormat,
      nil,
      AudioFileFlags.eraseFile.rawValue,
      &extAudioFile
    )

    guard status == noErr, let audioFile = extAudioFile else {
      throw NSError(domain: "KokoroTTS", code: 3, userInfo: [NSLocalizedDescriptionKey: "Failed to create M4A file: \(status)"])
    }

    defer {
      ExtAudioFileDispose(audioFile)
    }

    // Define the input format (PCM Float32)
    var inputFormat = AudioStreamBasicDescription(
      mSampleRate: format.sampleRate,
      mFormatID: kAudioFormatLinearPCM,
      mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
      mBytesPerPacket: 4,
      mFramesPerPacket: 1,
      mBytesPerFrame: 4,
      mChannelsPerFrame: 1,
      mBitsPerChannel: 32,
      mReserved: 0
    )

    // Set the client data format (what we'll provide)
    status = ExtAudioFileSetProperty(
      audioFile,
      kExtAudioFileProperty_ClientDataFormat,
      UInt32(MemoryLayout<AudioStreamBasicDescription>.size),
      &inputFormat
    )

    guard status == noErr else {
      throw NSError(domain: "KokoroTTS", code: 4, userInfo: [NSLocalizedDescriptionKey: "Failed to set client format: \(status)"])
    }

    // Write audio data in chunks
    let chunkSize = 8192
    var offset = 0

    while offset < audioSamples.count {
      let remainingSamples = audioSamples.count - offset
      let framesToWrite = min(chunkSize, remainingSamples)

      try audioSamples.withUnsafeBufferPointer { samplesPtr in
        let chunkPtr = samplesPtr.baseAddress! + offset

        var bufferList = AudioBufferList(
          mNumberBuffers: 1,
          mBuffers: AudioBuffer(
            mNumberChannels: 1,
            mDataByteSize: UInt32(framesToWrite * MemoryLayout<Float>.size),
            mData: UnsafeMutableRawPointer(mutating: chunkPtr)
          )
        )

        status = ExtAudioFileWrite(audioFile, UInt32(framesToWrite), &bufferList)

        guard status == noErr else {
          throw NSError(domain: "KokoroTTS", code: 5, userInfo: [NSLocalizedDescriptionKey: "Failed to write audio data: \(status)"])
        }
      }

      offset += framesToWrite
    }
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
