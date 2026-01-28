import AppKit
import SwiftUI
import MLX

/// App delegate that provides macOS Services integration for the TTS functionality.
/// This allows users to select text in any app and use "Speak with Kokoro" from the Services menu.
class AppDelegate: NSObject, NSApplicationDelegate {
  /// The shared view model - created immediately so it's available for Services
  lazy var model: KokoroTTSModel = {
    // Configure MLX GPU settings before creating the model
    Memory.cacheLimit = 50 * 1024 * 1024
    Memory.memoryLimit = 900 * 1024 * 1024
    return KokoroTTSModel()
  }()

  /// Text received from Services before the model was ready
  private var pendingText: String?

  /// Tracks if we're handling a service request (to suppress window activation)
  private var handlingServiceRequest = false

  /// Tracks if app was active when service request started
  private var wasActiveBeforeService = false

  func applicationDidFinishLaunching(_ notification: Notification) {
    // Initialize the model early so it's ready for service requests
    _ = model

    // Register this object as a service provider
    NSApp.servicesProvider = self

    // Register the types we accept for services
    NSApp.registerServicesMenuSendTypes([.string], returnTypes: [])

    // Update the Services menu
    NSUpdateDynamicServices()

    // Observe window visibility to hide windows during service requests
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(windowDidBecomeVisible(_:)),
      name: NSWindow.didBecomeKeyNotification,
      object: nil
    )
  }

  @objc private func windowDidBecomeVisible(_ notification: Notification) {
    // If we're handling a service request and the app wasn't active before,
    // hide the window immediately
    if handlingServiceRequest && !wasActiveBeforeService {
      if let window = notification.object as? NSWindow {
        window.orderOut(nil)
      }
    }
  }

  /// Service method called when user selects "Speak with Kokoro" from Services menu.
  /// The method name must match the NSMessage value in Info.plist.
  /// - Parameters:
  ///   - pboard: The pasteboard containing the selected text
  ///   - userData: User data from the service definition (unused)
  ///   - error: Error pointer to report failures
  @objc func speakWithKokoro(_ pboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>) {
    // Track service state
    wasActiveBeforeService = NSApp.isActive
    handlingServiceRequest = true

    // If app wasn't active, immediately hide all windows and prevent new ones from showing
    if !wasActiveBeforeService {
      for window in NSApp.windows {
        window.orderOut(nil)
      }
    }

    // Get the string from the pasteboard
    guard let items = pboard.pasteboardItems,
          let item = items.first,
          let text = item.string(forType: .string) ?? pboard.string(forType: .string),
          !text.isEmpty else {
      error.pointee = "No text was provided" as NSString
      handlingServiceRequest = false
      return
    }

    // Set the text in the input field and speak it
    DispatchQueue.main.async { [self] in
      model.inputText = text
      model.say(text)

      // Reset service state after a delay
      DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
        self.handlingServiceRequest = false
      }
    }
  }
}
