import SwiftUI
import UniformTypeIdentifiers

/// This view provides a simple interface for text-to-speech generation.
struct ContentView: View {
  /// The view model that manages the TTS engine and audio playback
  @ObservedObject var viewModel: KokoroTTSModel

  /// Tracks whether the text editor is focused
  @FocusState private var isTextEditorFocused: Bool

  /// Tracks whether user wants to edit text (clicked into text area while paused)
  @State private var isEditingText: Bool = false

  /// Event monitor for spacebar play/pause
  @State private var eventMonitor: Any?

  /// Tracks which star is being hovered (0 = none)
  @State private var hoveredStar: Int = 0

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

  /// Builds an AttributedString with the current word highlighted, preserving original formatting
  private func highlightedText() -> AttributedString {
    let originalText = viewModel.inputText
    var result = AttributedString(originalText)

    // Default everything to dimmed (not yet spoken)
    result.foregroundColor = Color(nsColor: .tertiaryLabelColor)

    // Find each token in the original text and apply styling
    var searchStart = originalText.startIndex

    for (index, token) in viewModel.allTokens.enumerated() {
      // Skip space tokens added between chunks
      if token.text == " " { continue }

      // Find this token in the original text
      guard let range = originalText.range(of: token.text, range: searchStart..<originalText.endIndex) else {
        continue
      }

      // Convert String range to AttributedString range
      let attrRange = Range<AttributedString.Index>(range, in: result)!

      if index == viewModel.currentTokenIndex {
        // Highlight the current word
        result[attrRange].backgroundColor = Color.accentColor
        result[attrRange].foregroundColor = Color.white
      } else if let start = token.start_ts, start <= viewModel.currentTime {
        // Already spoken - normal color
        result[attrRange].foregroundColor = Color(nsColor: .labelColor)
      }
      // Not yet spoken tokens keep the default dimmed color

      // Move search position forward to avoid matching the same word twice
      searchStart = range.upperBound
    }

    return result
  }

  /// Removes focus from the text editor so spacebar can control playback.
  private func unfocusTextEditor() {
    isTextEditorFocused = false
    NSApp.keyWindow?.makeFirstResponder(nil)
  }

  /// Shows a save panel and saves the audio to the selected location.
  private func saveAudio() {
    let savePanel = NSSavePanel()
    savePanel.allowedContentTypes = [.wav]
    savePanel.nameFieldStringValue = "kokoro_speech.wav"
    savePanel.title = "Save Audio"
    savePanel.message = "Choose a location to save the audio file"

    savePanel.begin { response in
      if response == .OK, let url = savePanel.url {
        do {
          try viewModel.saveAudio(to: url)
        } catch {
          // Show error alert
          let alert = NSAlert()
          alert.messageText = "Failed to save audio"
          alert.informativeText = error.localizedDescription
          alert.alertStyle = .warning
          alert.runModal()
        }
      }
    }
  }

  var body: some View {
    VStack(spacing: 16) {
      // Text input field / highlighted playback view
      Group {
        if viewModel.hasAudio && !viewModel.allTokens.isEmpty && !isEditingText {
          // Show highlighted text during playback or when paused (until user clicks to edit)
          ScrollView {
            Text(highlightedText())
              .font(.body)
              .frame(maxWidth: .infinity, alignment: .leading)
              .padding(.horizontal, 5)
          }
          .padding(8)
          .background(Color(nsColor: .textBackgroundColor))
          .cornerRadius(8)
          .overlay(
            RoundedRectangle(cornerRadius: 8)
              .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
          )
          .onTapGesture {
            // Allow editing when tapping the text area (only when not playing)
            if !viewModel.isPlaying {
              isEditingText = true
              isTextEditorFocused = true
            }
          }
        } else {
          // Show editable text editor
          TextEditor(text: $viewModel.inputText)
            .font(.body)
            .padding(8)
            .scrollContentBackground(.hidden)
            .background(Color(nsColor: .textBackgroundColor))
            .cornerRadius(8)
            .focused($isTextEditorFocused)
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
            .onChange(of: viewModel.inputText) {
              // Clear audio when text is edited so play button regenerates
              // But not if audio is currently being generated (e.g., from service)
              if viewModel.hasAudio && !viewModel.isGeneratingAudio {
                viewModel.clearAudio()
              }
            }
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
          HStack(spacing: 4) {
            ForEach(1...5, id: \.self) { star in
              let isHighlighted = hoveredStar > 0 && star <= hoveredStar
              Button {
                // Toggle: clicking same rating clears it, otherwise set new rating
                if viewModel.rating(for: viewModel.selectedVoice) == star {
                  viewModel.setRating(0, for: viewModel.selectedVoice)
                } else {
                  viewModel.setRating(star, for: viewModel.selectedVoice)
                }
              } label: {
                Image(systemName: isHighlighted ? "star.fill" : "star")
                  .foregroundColor(isHighlighted ? .yellow : Color(nsColor: .tertiaryLabelColor))
              }
              .buttonStyle(.plain)
              .onHover { hovering in
                if hovering {
                  hoveredStar = star
                }
              }
            }
          }
          .onHover { hovering in
            if !hovering {
              hoveredStar = 0
            }
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
        Spacer()
      }

      // Player controls - always visible
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
              set: {
                unfocusTextEditor()
                if viewModel.hasAudio {
                  viewModel.seek(to: $0)
                }
              }
            ),
            in: 0...max(viewModel.totalDuration, 0.01)
          )
          .disabled(!viewModel.hasAudio)

          Text(formatTime(viewModel.totalDuration))
            .font(.caption)
            .monospacedDigit()
            .foregroundColor(Color(nsColor: .secondaryLabelColor))
            .frame(width: 45, alignment: .leading)
        }

        // Playback buttons
        HStack {
          Spacer()

          HStack(spacing: 20) {
            // Back to start button
            Button {
              unfocusTextEditor()
              viewModel.pause()
              viewModel.seek(to: 0)
            } label: {
              Image(systemName: "backward.end.fill")
                .font(.title2)
                .help("Back to start")
            }
            .buttonStyle(.plain)
            .foregroundColor(viewModel.hasAudio ? Color(nsColor: .labelColor) : Color(nsColor: .tertiaryLabelColor))
            .disabled(!viewModel.hasAudio)

            // Play/Pause button - starts speaking if no audio, otherwise toggles
            Button {
              unfocusTextEditor()
              if viewModel.hasAudio {
                // Only exit edit mode when resuming, not when pausing
                if !viewModel.isPlaying {
                  isEditingText = false
                }
                viewModel.togglePlayPause()
              } else if !viewModel.inputText.isEmpty {
                isEditingText = false
                viewModel.say(viewModel.inputText)
              }
            } label: {
              Image(systemName: viewModel.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                .font(.largeTitle)
                .help(viewModel.hasAudio ? (viewModel.isPlaying ? "Pause" : "Play") : "Generate and play audio")
            }
            .buttonStyle(.plain)
            .foregroundColor(.accentColor)

            // Cancel generation button - only shown while generating
            if viewModel.isGeneratingAudio {
              Button {
                unfocusTextEditor()
                viewModel.cancelGeneration()
              } label: {
                Image(systemName: "hand.raised.fill")
                  .font(.title2)
                  .help("Stop generating audio")
              }
              .buttonStyle(.plain)
              .foregroundColor(Color(nsColor: .secondaryLabelColor))
            }
          }

          Spacer()

          // Save button - only enabled when audio exists and generation is complete
          Button {
            unfocusTextEditor()
            saveAudio()
          } label: {
            Image(systemName: "square.and.arrow.down")
              .font(.title2)
              .help(!viewModel.hasAudio ? "Generate audio before saving to file" : (viewModel.isGeneratingAudio ? "Wait for audio generation to complete" : "Save audio to file"))
          }
          .buttonStyle(.plain)
          .foregroundColor(!viewModel.hasAudio || viewModel.isGeneratingAudio ? Color(nsColor: .tertiaryLabelColor) : Color(nsColor: .labelColor))
          .disabled(!viewModel.hasAudio || viewModel.isGeneratingAudio)
        }
      }
      .padding(.vertical, 8)

    }
    .padding(20)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(Color(nsColor: .windowBackgroundColor))
    .onAppear {
      // Set up event monitor for spacebar play/pause and Escape to unfocus
      eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
        // Check for Escape key (keyCode 53) - unfocus text editor
        if event.keyCode == 53 {
          isTextEditorFocused = false
          NSApp.keyWindow?.makeFirstResponder(nil)
          return nil
        }

        // Check for spacebar (keyCode 49)
        if event.keyCode == 49 {
          // Check if a text view has focus - if so, let spacebar through for typing
          if let firstResponder = NSApp.keyWindow?.firstResponder,
             firstResponder is NSTextView {
            return event  // Let text view handle the space
          }
          // Toggle play/pause if audio exists, otherwise start speaking
          if viewModel.hasAudio {
            // Only exit edit mode when resuming, not when pausing
            if !viewModel.isPlaying {
              isEditingText = false
            }
            viewModel.togglePlayPause()
          } else if !viewModel.inputText.isEmpty {
            isEditingText = false
            viewModel.say(viewModel.inputText)
          }
          return nil  // Consume the event
        }
        return event  // Pass through other events
      }
    }
    .onDisappear {
      // Clean up event monitor
      if let monitor = eventMonitor {
        NSEvent.removeMonitor(monitor)
        eventMonitor = nil
      }
    }
    .onChange(of: viewModel.selectedVoice) {
      // Clear audio when voice changes so play button regenerates
      if viewModel.hasAudio {
        viewModel.clearAudio()
      }
    }
    .onChange(of: viewModel.speechSpeed) {
      // Clear audio when speed changes so play button regenerates
      if viewModel.hasAudio {
        viewModel.clearAudio()
      }
    }
    .onChange(of: viewModel.isPlaying) { oldValue, newValue in
      // Reset editing mode when playback starts (including from service)
      if newValue && !oldValue {
        isEditingText = false
      }
    }
  }
}

#Preview {
  ContentView(viewModel: KokoroTTSModel())
}
