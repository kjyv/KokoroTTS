import SwiftUI
import MLX

/// The main application entry point for the Kokoro TTS test app.
/// This app demonstrates the Kokoro text-to-speech engine with MLX acceleration.
@main
struct KokoroTestApp: App {
  /// The app delegate that handles macOS Services integration
  @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

  /// The main view model that manages the TTS engine and application state
  let model = TestAppModel()

  /// Initializes the application and configures MLX GPU settings.
  init() {
    // Configure MLX GPU cache limit (50 MB)
    Memory.cacheLimit = 50 * 1024 * 1024
    // Configure MLX GPU memory limit (900 MB)
    Memory.memoryLimit = 900 * 1024 * 1024
  }

  var body: some Scene {
    WindowGroup {
      ContentView(viewModel: model)
        .frame(minWidth: 350, minHeight: 300)
        .onAppear {
          // Connect the model to the app delegate for Services support
          appDelegate.model = model
        }
    }
    .defaultSize(width: 550, height: 550)
  }
}
