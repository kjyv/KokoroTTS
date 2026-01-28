import Foundation

// MARK: - Text Preprocessing

extension KokoroTTSModel {
  /// Converts slashes between words to dashes for better speech flow.
  /// For example: "and/or" becomes "and - or".
  /// - Parameter text: The input text
  /// - Returns: Text with word/word patterns converted to word - or
  func convertSlashesToDashes(_ text: String) -> String {
    // Replace slashes between word characters with " - "
    let pattern = "(?<=\\p{L})/(?=\\p{L})"
    guard let regex = try? NSRegularExpression(pattern: pattern) else {
      return text
    }
    let range = NSRange(text.startIndex..., in: text)
    return regex.stringByReplacingMatches(in: text, range: range, withTemplate: " - ")
  }

  /// Removes hyphens from compound words to improve speech synthesis.
  /// For example, "time-delayed" becomes "time delayed".
  /// - Parameter text: The input text
  /// - Returns: Text with hyphens between words replaced by spaces
  func removeHyphensFromCompoundWords(_ text: String) -> String {
    // Replace hyphens between word characters with spaces
    // This matches patterns like "word-word" but not standalone hyphens or dashes
    let pattern = "(?<=\\p{L})-(?=\\p{L})"
    guard let regex = try? NSRegularExpression(pattern: pattern) else {
      return text
    }
    let range = NSRange(text.startIndex..., in: text)
    return regex.stringByReplacingMatches(in: text, range: range, withTemplate: " ")
  }

  /// Converts parenthetical phrases to use dashes for better speech flow.
  /// For example: "interrelates (or not) as soon" becomes "interrelates - or not - as soon"
  /// When at end of sentence: "interrelates (or not)." becomes "interrelates - or not."
  /// - Parameter text: The input text
  /// - Returns: Text with parentheticals converted to dashes
  func convertParentheticalsToDashes(_ text: String) -> String {
    var result = text

    // Pattern matches (content) followed by optional punctuation
    // Group 1: content inside parentheses
    // Group 2: optional punctuation immediately after
    // Group 3: what follows (space + word, or end)
    let pattern = "\\(([^)]+)\\)([.,;:!?]?)(?=(\\s+\\w|\\s*$))"
    guard let regex = try? NSRegularExpression(pattern: pattern) else {
      return text
    }

    let range = NSRange(result.startIndex..., in: result)
    let matches = regex.matches(in: result, range: range)

    // Process matches in reverse order to preserve indices
    for match in matches.reversed() {
      guard let contentRange = Range(match.range(at: 1), in: result),
            let fullRange = Range(match.range, in: result) else {
        continue
      }

      let content = String(result[contentRange])
      let punctuation = match.range(at: 2).length > 0
        ? String(result[Range(match.range(at: 2), in: result)!])
        : ""

      // Check what follows to decide on trailing dash
      let followedByMoreText = match.range(at: 3).length > 0 &&
        Range(match.range(at: 3), in: result).map { !result[$0].trimmingCharacters(in: .whitespaces).isEmpty } ?? false

      let replacement: String
      if punctuation.isEmpty && followedByMoreText {
        // Middle of sentence: "word (content) word" → "word - content - word"
        replacement = "- \(content) -"
      } else {
        // End of clause/sentence: "word (content)." → "word - content."
        replacement = "- \(content)\(punctuation)"
      }

      result.replaceSubrange(fullRange, with: replacement)
    }

    return result
  }

  /// Splits text into chunks of sentences for processing within token limits.
  /// Also splits on headlines (lines followed by empty lines).
  /// - Parameters:
  ///   - text: The text to split
  ///   - sentencesPerChunk: Maximum number of sentences per chunk
  /// - Returns: Array of text chunks
  func splitIntoChunks(_ text: String, sentencesPerChunk: Int = 2) -> [String] {
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
}
