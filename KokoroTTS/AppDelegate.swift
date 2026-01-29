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

  /// Saved window frames to restore positions after service request
  private var savedWindowFrames: [NSWindow: NSRect] = [:]

  func applicationDidFinishLaunching(_ notification: Notification) {
    // Initialize the model early so it's ready for service requests
    _ = model

    // Register this object as a service provider
    NSApp.servicesProvider = self

    // Register the types we accept for services
    NSApp.registerServicesMenuSendTypes([.string], returnTypes: [])

    // Update the Services menu
    NSUpdateDynamicServices()

    // Set frame autosave name for the main window to remember position
    DispatchQueue.main.async {
      if let window = NSApp.windows.first {
        window.setFrameAutosaveName("KokoroTTSMainWindow")
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
    let wasActive = NSApp.isActive

    // Save window positions before any changes
    for window in NSApp.windows {
      savedWindowFrames[window] = window.frame
    }

    // Get the string from the pasteboard
    guard let items = pboard.pasteboardItems,
          let item = items.first,
          let text = item.string(forType: .string) ?? pboard.string(forType: .string),
          !text.isEmpty else {
      error.pointee = "No text was provided" as NSString
      return
    }

    // Temporarily become an accessory app to prevent activation
    if !wasActive {
      NSApp.setActivationPolicy(.accessory)
    }

    // Set the text in the input field and speak it
    DispatchQueue.main.async { [self] in
      model.inputText = text
      model.say(text)

      // Restore window positions after SwiftUI processes state changes
      DispatchQueue.main.async { [self] in
        for (window, frame) in savedWindowFrames {
          window.setFrame(frame, display: false)
        }
        savedWindowFrames.removeAll()

        // Restore regular activation policy
        if !wasActive {
          NSApp.setActivationPolicy(.regular)
        }
      }
    }
  }
}
