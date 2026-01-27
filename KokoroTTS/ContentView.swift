import SwiftUI

/// This view provides a simple interface for text-to-speech generation.
struct ContentView: View {
  /// The view model that manages the TTS engine and audio playback
  @ObservedObject var viewModel: TestAppModel

  /// Returns the flag emoji for a voice based on its two-letter language/gender code prefix.
  /// Format: first letter = language (a=American, b=British), second letter = gender (f=female, m=male)
  private func flagForVoice(_ voice: String) -> String {
    guard voice.count >= 2 else { return "🌐" }
    let langCode = voice.first
    switch langCode {
    case "a": return "🇺🇸"  // American English
    case "b": return "🇬🇧"  // British English
    case "e": return "🇪🇸"  // Spanish
    case "f": return "🇫🇷"  // French
    case "h": return "🇮🇳"  // Hindi
    case "i": return "🇮🇹"  // Italian
    case "j": return "🇯🇵"  // Japanese
    case "p": return "🇧🇷"  // Portuguese (Brazilian)
    case "z": return "🇨🇳"  // Chinese
    default: return "🌐"
    }
  }

  /// Returns a gender icon based on the second letter of the voice code.
  private func genderIconForVoice(_ voice: String) -> String {
    guard voice.count >= 2 else { return "" }
    let genderCode = voice[voice.index(voice.startIndex, offsetBy: 1)]
    switch genderCode {
    case "f": return "👩‍🦰"
    case "m": return "👨🏻‍🦰"
    default: return ""
    }
  }

  /// Extracts the display name from a voice identifier (e.g., "af_bella" -> "Bella").
  private func displayNameForVoice(_ voice: String) -> String {
    // Split by underscore and take the part after it
    if let underscoreIndex = voice.firstIndex(of: "_") {
      let nameStart = voice.index(after: underscoreIndex)
      let name = String(voice[nameStart...])
      // Capitalize the first letter
      return name.prefix(1).uppercased() + name.dropFirst()
    }
    return voice
  }

  /// Returns a string of star characters representing the rating for a voice.
  private func ratingString(for voice: String) -> String {
    let rating = viewModel.rating(for: voice)
    if rating > 0 {
      return " " + String(repeating: "★", count: rating)
    }
    return ""
  }

  /// Formats a time value in seconds to MM:SS format.
  private func formatTime(_ time: Double) -> String {
    let totalSeconds = Int(time)
    let minutes = totalSeconds / 60
    let seconds = totalSeconds % 60
    return String(format: "%d:%02d", minutes, seconds)
  }

  var body: some View {
    VStack(spacing: 16) {
      // Text input field for entering speech content
      TextEditor(text: $viewModel.inputText)
        .font(.body)
        .padding(8)
        .scrollContentBackground(.hidden)
        .background(Color(nsColor: .textBackgroundColor))
        .cornerRadius(8)
        .overlay(
          RoundedRectangle(cornerRadius: 8)
            .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
        )
        .overlay(alignment: .topLeading) {
          if viewModel.inputText.isEmpty {
            Text("Type something to say...")
              .font(.body)
              .foregroundColor(Color(nsColor: .placeholderTextColor))
              .padding(.horizontal, 13)
              .padding(.vertical, 8)
              .allowsHitTesting(false)
          }
        }
        .frame(minHeight: 100)

      // Voice selection picker and rating
      HStack {
        Text("Voice:")
          .foregroundColor(Color(nsColor: .labelColor))
        Picker("", selection: $viewModel.selectedVoice) {
          ForEach(viewModel.voiceNames, id: \.self) { voice in
            Text("\(flagForVoice(voice)) \(genderIconForVoice(voice)) \(displayNameForVoice(voice))\(ratingString(for: voice))")
              .tag(voice)
          }
        }
        .pickerStyle(.menu)
        .frame(minWidth: 150)

        Spacer()

        // Star rating for selected voice
        HStack(spacing: 4) {
          Text("Rating:")
            .foregroundColor(Color(nsColor: .labelColor))
          ForEach(1...5, id: \.self) { star in
            Button {
              // Toggle: clicking same rating clears it, otherwise set new rating
              if viewModel.rating(for: viewModel.selectedVoice) == star {
                viewModel.setRating(0, for: viewModel.selectedVoice)
              } else {
                viewModel.setRating(star, for: viewModel.selectedVoice)
              }
            } label: {
              Image(systemName: star <= viewModel.rating(for: viewModel.selectedVoice) ? "star.fill" : "star")
                .foregroundColor(star <= viewModel.rating(for: viewModel.selectedVoice) ? .yellow : Color(nsColor: .tertiaryLabelColor))
            }
            .buttonStyle(.plain)
          }
        }
      }

      // Speed control
      HStack {
        Text("Speed:")
          .foregroundColor(Color(nsColor: .labelColor))
        Slider(value: Binding(
          get: { Double(viewModel.speechSpeed) },
          set: { viewModel.speechSpeed = Float($0) }
        ), in: 0.5...2.0, step: 0.1)
        .frame(width: 150)
        Text(String(format: "%.1fx", viewModel.speechSpeed))
          .foregroundColor(Color(nsColor: .secondaryLabelColor))
          .monospacedDigit()
          .frame(width: 40)
        Button("Reset") {
          viewModel.speechSpeed = 1.0
        }
        .buttonStyle(.plain)
        .foregroundColor(.accentColor)
        Spacer()
      }

      // Button to trigger text-to-speech synthesis
      Button {
        if !viewModel.inputText.isEmpty {
          viewModel.say(viewModel.inputText)
        } else {
          viewModel.say("Please type something first")
        }
      } label: {
        Text("Speak")
          .frame(maxWidth: .infinity)
          .padding(.vertical, 8)
      }
      .buttonStyle(.borderedProminent)
      .controlSize(.large)

      // Player controls
      if viewModel.hasAudio {
        VStack(spacing: 8) {
          // Seek slider
          HStack(spacing: 12) {
            Text(formatTime(viewModel.currentTime))
              .font(.caption)
              .monospacedDigit()
              .foregroundColor(Color(nsColor: .secondaryLabelColor))
              .frame(width: 45, alignment: .trailing)

            Slider(
              value: Binding(
                get: { viewModel.currentTime },
                set: { viewModel.seek(to: $0) }
              ),
              in: 0...max(viewModel.totalDuration, 0.01)
            )

            Text(formatTime(viewModel.totalDuration))
              .font(.caption)
              .monospacedDigit()
              .foregroundColor(Color(nsColor: .secondaryLabelColor))
              .frame(width: 45, alignment: .leading)
          }

          // Playback buttons
          HStack(spacing: 20) {
            // Restart button
            Button {
              viewModel.playFromStart()
            } label: {
              Image(systemName: "backward.end.fill")
                .font(.title2)
            }
            .buttonStyle(.plain)
            .foregroundColor(Color(nsColor: .labelColor))

            // Play/Pause button
            Button {
              viewModel.togglePlayPause()
            } label: {
              Image(systemName: viewModel.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                .font(.largeTitle)
            }
            .buttonStyle(.plain)
            .foregroundColor(.accentColor)

            // Stop button
            Button {
              viewModel.stop()
            } label: {
              Image(systemName: "stop.fill")
                .font(.title2)
            }
            .buttonStyle(.plain)
            .foregroundColor(Color(nsColor: .labelColor))
          }
        }
        .padding(.vertical, 8)
      }

    }
    .padding(20)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(Color(nsColor: .windowBackgroundColor))
  }
}

#Preview {
  ContentView(viewModel: TestAppModel())
}
