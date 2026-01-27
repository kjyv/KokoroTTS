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
  }
}
