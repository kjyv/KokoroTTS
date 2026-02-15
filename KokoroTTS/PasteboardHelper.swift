import AppKit

/// Utility for extracting text from the pasteboard with rich text formatting awareness.
/// Detects headlines in RTF content (by font size) and inserts empty lines after them
/// so the TTS engine creates natural pauses between headings and body text.
enum PasteboardHelper {
  /// Reads RTF from the pasteboard, detects headline paragraphs by font size,
  /// and returns plain text with empty lines inserted after headlines.
  /// Returns nil if no RTF is available, no font info is present, or no headlines are detected.
  static func extractTextPreservingHeadlines(from pasteboard: NSPasteboard) -> String? {
    guard let rtfData = pasteboard.data(forType: .rtf),
          let attrString = NSAttributedString(rtf: rtfData, documentAttributes: nil) else {
      return nil
    }

    let text = attrString.string
    let nsString = text as NSString
    guard nsString.length > 0 else { return nil }

    // Parse each line and record its dominant font size
    struct LineInfo {
      let text: String
      let fontSize: CGFloat
      let isEmpty: Bool
    }

    var lines: [LineInfo] = []
    var index = 0

    while index < nsString.length {
      let lineRange = nsString.lineRange(for: NSRange(location: index, length: 0))
      let lineText = nsString.substring(with: lineRange)
        .trimmingCharacters(in: .newlines)
      let trimmed = lineText.trimmingCharacters(in: .whitespaces)

      if trimmed.isEmpty {
        lines.append(LineInfo(text: "", fontSize: 0, isEmpty: true))
      } else {
        // Find the largest font size used in this line
        var maxFontSize: CGFloat = 0
        attrString.enumerateAttribute(.font, in: lineRange) { value, _, _ in
          if let font = value as? NSFont {
            maxFontSize = max(maxFontSize, font.pointSize)
          }
        }
        lines.append(LineInfo(text: lineText, fontSize: maxFontSize, isEmpty: false))
      }

      index = NSMaxRange(lineRange)
    }

    // Need at least 2 content lines with font info to compare sizes
    let contentLines = lines.filter { !$0.isEmpty && $0.fontSize > 0 }
    guard contentLines.count >= 2 else { return nil }

    // Determine the body font size as the most common size (rounded to nearest point)
    let sizeGroups = Dictionary(grouping: contentLines, by: { round($0.fontSize) })
    guard let bodySize = sizeGroups.max(by: { $0.value.count < $1.value.count })?.key,
          bodySize > 0 else { return nil }

    // A headline must be at least 15% larger than body text
    let headlineThreshold = bodySize * 1.15

    // Bail out if no lines qualify as headlines
    guard contentLines.contains(where: { $0.fontSize >= headlineThreshold }) else { return nil }

    // Rebuild the text, inserting an empty line after each headline
    var resultLines: [String] = []
    for (i, line) in lines.enumerated() {
      resultLines.append(line.text)

      // After a headline, ensure there's an empty line for a TTS pause
      if !line.isEmpty && line.fontSize >= headlineThreshold {
        let nextIndex = i + 1
        let nextIsAlreadyEmpty = nextIndex < lines.count && lines[nextIndex].isEmpty
        if !nextIsAlreadyEmpty {
          resultLines.append("")
        }
      }
    }

    return resultLines.joined(separator: "\n")
  }

  /// Extracts text from the pasteboard, trying RTF headline detection first,
  /// then falling back to plain text. Returns nil if no text is available.
  static func extractText(from pasteboard: NSPasteboard) -> String? {
    if let richText = extractTextPreservingHeadlines(from: pasteboard) {
      return richText
    }
    guard let items = pasteboard.pasteboardItems,
          let item = items.first,
          let text = item.string(forType: .string) ?? pasteboard.string(forType: .string),
          !text.isEmpty else {
      return nil
    }
    return text
  }
}
