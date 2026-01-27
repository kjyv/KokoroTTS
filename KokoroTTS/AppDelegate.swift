import AppKit
import SwiftUI

/// App delegate that provides macOS Services integration for the TTS functionality.
/// This allows users to select text in any app and use "Speak with Kokoro" from the Services menu.
class AppDelegate: NSObject, NSApplicationDelegate {
  /// Reference to the shared view model
  var model: TestAppModel? {
    didSet {
      // Process any pending text that arrived before the model was ready
      if let model = model, let text = pendingText {
        pendingText = nil
        DispatchQueue.main.async {
          model.inputText = text
          model.say(text)
        }
      }
    }
  }

  /// Text received from Services before the model was ready
  private var pendingText: String?

  func applicationDidFinishLaunching(_ notification: Notification) {
    // Register this object as a service provider
    NSApp.servicesProvider = self

    // Register the types we accept for services
    NSApp.registerServicesMenuSendTypes([.string], returnTypes: [])

    // Update the Services menu
    NSUpdateDynamicServices()
  }

  /// Service method called when user selects "Speak with Kokoro" from Services menu.
  /// The method name must match the NSMessage value in Info.plist.
  /// - Parameters:
  ///   - pboard: The pasteboard containing the selected text
  ///   - userData: User data from the service definition (unused)
  ///   - error: Error pointer to report failures
  @objc func speakWithKokoro(_ pboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>) {
    // Get the string from the pasteboard
    guard let items = pboard.pasteboardItems,
          let item = items.first,
          let text = item.string(forType: .string) ?? pboard.string(forType: .string),
          !text.isEmpty else {
      error.pointee = "No text was provided" as NSString
      return
    }

    // Bring the app to front
    NSApp.activate(ignoringOtherApps: true)

    // Set the text in the input field and speak it
    if let model = model {
      DispatchQueue.main.async {
        model.inputText = text
        model.say(text)
      }
    } else {
      // Model not ready yet (app just launched), queue the text
      pendingText = text
    }
  }
}
