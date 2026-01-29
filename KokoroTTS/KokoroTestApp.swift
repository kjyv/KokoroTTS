import SwiftUI

/// The main application entry point for the Kokoro TTS test app.
/// This app demonstrates the Kokoro text-to-speech engine with MLX acceleration.
@main
struct KokoroTestApp: App {
  /// The app delegate that handles macOS Services integration and owns the model
  @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

  var body: some Scene {
    WindowGroup {
      ContentView(viewModel: appDelegate.model)
        .frame(minWidth: 350, minHeight: 300)
    }
    .defaultSize(width: 550, height: 550)
    .commands {
      CommandGroup(replacing: .appInfo) {
        Button("About Kokoro TTS") {
          NSApplication.shared.orderFrontStandardAboutPanel(options: [
            .applicationIcon: NSApp.applicationIconImage as Any,
            .applicationName: "Kokoro TTS",
            .version: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0",
            .credits: NSAttributedString(
              string: "GitHub: https://github.com/kjyv/KokoroTTS",
              attributes: [
                .link: URL(string: "https://github.com/kjyv/KokoroTTS")!,
                .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
              ]
            )
          ])
        }
      }
      CommandGroup(replacing: .help) {
        HelpMenuButton()
      }
    }

    Window("Kokoro TTS Help", id: "help") {
      HelpView()
    }
    .windowResizability(.contentSize)
  }
}

/// A button that opens the help window using the SwiftUI environment.
struct HelpMenuButton: View {
  @Environment(\.openWindow) private var openWindow

  var body: some View {
    Button("Kokoro TTS Help") {
      openWindow(id: "help")
    }
    .keyboardShortcut("?", modifiers: .command)
  }
}
