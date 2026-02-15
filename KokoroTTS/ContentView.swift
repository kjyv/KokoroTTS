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

  /// Normalizes Unicode quotation marks to ASCII equivalents so token text from the TTS engine
  /// can be matched against the original input even when it contains smart quotes.
  private static func normalizeQuotes(_ text: String) -> String {
    text.replacingOccurrences(of: "\u{2018}", with: "'")
      .replacingOccurrences(of: "\u{2019}", with: "'")
      .replacingOccurrences(of: "\u{201C}", with: "\"")
      .replacingOccurrences(of: "\u{201D}", with: "\"")
  }

  /// Finds the next whole-word occurrence of `word` in `text` starting from `start`.
  /// Prevents matching substrings inside longer words (e.g., "or" inside "for").
  private func findWholeWord(_ word: String, in text: String, from start: String.Index) -> Range<String.Index>? {
    var searchFrom = start
    while let range = text.range(of: word, range: searchFrom..<text.endIndex) {
      let beforeChar = range.lowerBound == text.startIndex ? nil : text[text.index(before: range.lowerBound)]
      let afterChar = range.upperBound == text.endIndex ? nil : text[range.upperBound]
      let beforeOK = beforeChar == nil || !(beforeChar!.isLetter || beforeChar!.isNumber)
      let afterOK = afterChar == nil || !(afterChar!.isLetter || afterChar!.isNumber)
      if beforeOK && afterOK {
        return range
      }
      searchFrom = range.upperBound
      if searchFrom >= text.endIndex { break }
    }
    return nil
  }

  /// Builds an AttributedString with the current word highlighted, preserving original formatting.
  ///
  /// Tokens come from preprocessed text (where parentheticals become dashes, etc.), so matching
  /// uses whole-word search with Unicode normalization to handle mismatches. Characters between
  /// spoken tokens (like parentheses) are filled in as spoken via gap-filling.
  private func highlightedText() -> AttributedString {
    let originalText = viewModel.inputText
    var result = AttributedString(originalText)

    // Default everything to dimmed (not yet spoken)
    result.foregroundColor = Color(nsColor: .tertiaryLabelColor)

    // Normalize quotes for matching (smart quotes -> ASCII) since TTS may normalize them.
    // This preserves character count so we can maintain parallel indices.
    let searchText = Self.normalizeQuotes(originalText)

    // Maintain parallel positions in both original and normalized text
    var normSearchStart = searchText.startIndex
    var origSearchStart = originalText.startIndex

    // Track end of last spoken region for gap filling
    var lastSpokenOrigEnd: String.Index?

    for (index, token) in viewModel.allTokens.enumerated() {
      // Skip space tokens added between chunks
      if token.text == " " { continue }

      let normalizedToken = Self.normalizeQuotes(token.text)

      // Use whole-word matching for tokens containing letters/numbers (prevents "or" matching
      // inside "for"). For punctuation-only tokens (quotes, commas, etc.), use simple substring
      // matching since they naturally appear adjacent to letters.
      let tokenHasWordChars = normalizedToken.contains { $0.isLetter || $0.isNumber }
      let range: Range<String.Index>?
      if tokenHasWordChars {
        range = findWholeWord(normalizedToken, in: searchText, from: normSearchStart)
      } else {
        range = searchText.range(of: normalizedToken, range: normSearchStart..<searchText.endIndex)
      }

      guard let range else {
        // Token not found - likely a preprocessing artifact (e.g., "-" from converted parenthetical)
        // or a Unicode mismatch. Skip it; gap-filling will color the skipped area when the next
        // spoken token is found.
        continue
      }

      // Map the match position to the original text using parallel character offsets
      let skipCount = searchText.distance(from: normSearchStart, to: range.lowerBound)
      let tokenLength = searchText.distance(from: range.lowerBound, to: range.upperBound)
      let origMatchStart = originalText.index(origSearchStart, offsetBy: skipCount)
      let origMatchEnd = originalText.index(origMatchStart, offsetBy: tokenLength)
      let origRange = origMatchStart..<origMatchEnd

      let isCurrent = index == viewModel.currentTokenIndex
      let isSpoken = token.start_ts.map { $0 <= viewModel.currentTime } ?? false

      if isCurrent || isSpoken {
        // Fill gap: color characters between last spoken position and this token as spoken.
        // This handles parentheses, preprocessing artifacts, and any skipped characters.
        if let lastEnd = lastSpokenOrigEnd, lastEnd < origMatchStart {
          if let gapAttrRange = Range<AttributedString.Index>(lastEnd..<origMatchStart, in: result) {
            result[gapAttrRange].foregroundColor = Color(nsColor: .labelColor)
          }
        }
        lastSpokenOrigEnd = origMatchEnd
      }

      if let attrRange = Range<AttributedString.Index>(origRange, in: result) {
        if isCurrent {
          // Highlight the current word
          result[attrRange].backgroundColor = Color.accentColor
          result[attrRange].foregroundColor = Color.white
        } else if isSpoken {
          // Already spoken - normal color
          result[attrRange].foregroundColor = Color(nsColor: .labelColor)
        }
      }

      // Move search positions forward
      normSearchStart = range.upperBound
      origSearchStart = origMatchEnd
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
    savePanel.title = "Save Audio"
    savePanel.message = "Choose a location to save the audio file"
    savePanel.allowedContentTypes = [.wav]
    savePanel.nameFieldStringValue = "kokoro_speech.wav"

    // Create format picker accessory view
    let formatPicker = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 150, height: 24), pullsDown: false)
    formatPicker.addItems(withTitles: ["WAV (Uncompressed)", "M4A (AAC)"])
    formatPicker.selectItem(at: 0)

    let label = NSTextField(labelWithString: "Format:")
    label.frame = NSRect(x: 0, y: 0, width: 50, height: 24)

    let accessoryView = NSView(frame: NSRect(x: 0, y: 0, width: 220, height: 40))
    label.frame.origin = NSPoint(x: 0, y: 6)
    formatPicker.frame.origin = NSPoint(x: 55, y: 8)
    accessoryView.addSubview(label)
    accessoryView.addSubview(formatPicker)

    savePanel.accessoryView = accessoryView

    // Handle format changes - only update allowedContentTypes, let the system handle extension
    class FormatPickerTarget: NSObject {
      let savePanel: NSSavePanel

      init(savePanel: NSSavePanel) {
        self.savePanel = savePanel
      }

      @objc func formatChanged(_ sender: NSPopUpButton) {
        let isWAV = sender.indexOfSelectedItem == 0
        savePanel.allowedContentTypes = isWAV ? [.wav] : [.mpeg4Audio]
      }
    }

    let target = FormatPickerTarget(savePanel: savePanel)
    formatPicker.target = target
    formatPicker.action = #selector(FormatPickerTarget.formatChanged(_:))

    savePanel.begin { response in
      // Keep target alive until panel closes
      _ = target

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
