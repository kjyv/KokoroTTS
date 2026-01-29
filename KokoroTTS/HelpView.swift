import SwiftUI

/// A help window displaying usage information for Kokoro TTS.
struct HelpView: View {
  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 20) {
        // Header
        HStack {
          Image(nsImage: NSApp.applicationIconImage)
            .resizable()
            .frame(width: 48, height: 48)
          Text("Kokoro TTS Help")
            .font(.largeTitle)
            .fontWeight(.bold)
        }

        Text("A macOS application for the Kokoro TTS (Text-to-Speech) model, allowing high-quality offline speech synthesis. Integrates as a macOS service to speak selected text quickly.")
          .foregroundColor(Color(nsColor: .secondaryLabelColor))

        Divider()

        // Usage
        sectionHeader("Usage")

        Text("Using the Service")
          .font(.headline)
        Text("Select any text in any application and select \"Speak with Kokoro\" from the context menu. Or press **\u{2318}\u{21E7}P** (Command+Shift+P) to speak it.")

        Text("To change the keyboard shortcut, go to **System Settings \u{2192} Keyboard \u{2192} Keyboard Shortcuts \u{2192} Services \u{2192} Text \u{2192} Speak with Kokoro**.")
          .foregroundColor(Color(nsColor: .secondaryLabelColor))
          .font(.callout)

        Text("Note: The service menu item will only appear after you've started the app for the first time.")
          .foregroundColor(Color(nsColor: .secondaryLabelColor))
          .font(.callout)

        Text("Using the App Directly")
          .font(.headline)
          .padding(.top, 8)
        Text("Paste or type text directly into the app's text field and press the play button.")

        Text("Saving Audio Files")
          .font(.headline)
          .padding(.top, 8)
        Text("After generating audio, click the save button (download icon) on the right side of the playback controls to export the audio. You can choose any location and filename for the exported file.")

        Text("Supported formats:")
          .fontWeight(.medium)
          .padding(.top, 4)
        VStack(alignment: .leading, spacing: 4) {
          Text("\u{2022} **WAV** - Uncompressed, highest quality, larger file size")
          Text("\u{2022} **M4A** (AAC) - Compressed, smaller file size, widely compatible")
        }
        .foregroundColor(Color(nsColor: .secondaryLabelColor))
        .font(.callout)

        Divider()

        // Features
        sectionHeader("Features")

        featureRow("High-Quality TTS", description: "Leverages the Kokoro neural TTS model for natural-sounding speech synthesis")
        featureRow("Multiple Voices", description: "Supports different voice options with rating system")
        featureRow("Fast Generation", description: "Faster than real-time audio generation")
        featureRow("Apple Silicon Optimized", description: "Uses the MLX machine learning framework for GPU acceleration")
        featureRow("Offline", description: "Works completely offline with no internet connection required")

        Divider()

        // Supported Platforms
        sectionHeader("Supported Platforms")
        Text("macOS 15.0 or later")

        Divider()

        // License
        sectionHeader("License")
        Text("This project is licensed under the Apache 2.0 License.")
          .foregroundColor(Color(nsColor: .secondaryLabelColor))

        Spacer()
      }
      .padding(24)
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .frame(width: 500, height: 600)
  }

  private func sectionHeader(_ title: String) -> some View {
    Text(title)
      .font(.title2)
      .fontWeight(.semibold)
  }

  private func featureRow(_ title: String, description: String) -> some View {
    HStack(alignment: .top, spacing: 8) {
      Image(systemName: "checkmark.circle.fill")
        .foregroundColor(.accentColor)
      VStack(alignment: .leading, spacing: 2) {
        Text(title)
          .fontWeight(.medium)
        Text(description)
          .foregroundColor(Color(nsColor: .secondaryLabelColor))
          .font(.callout)
      }
    }
  }
}

#Preview {
  HelpView()
}
