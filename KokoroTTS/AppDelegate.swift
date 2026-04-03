import AppKit
import SwiftUI
import MLX
import ServiceManagement

/// App delegate that provides macOS Services integration for the TTS functionality.
/// This allows users to select text in any app and use "Speak with Kokoro" from the Services menu.
class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSMenuDelegate {
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

  /// Reference to main window (kept to restore after hide)
  private var mainWindow: NSWindow?

  /// Menu bar status item
  private var statusItem: NSStatusItem?

  /// UserDefaults keys
  private let hideFromDockKey = "hideFromDock"
  private let autoStartKey = "autoStartEnabled"

  func applicationDidFinishLaunching(_ notification: Notification) {
    // Initialize the model early so it's ready for service requests
    _ = model

    // Register this object as a service provider
    NSApp.servicesProvider = self

    // Register the types we accept for services (RTF for headline detection, string as fallback)
    NSApp.registerServicesMenuSendTypes([.rtf, .string], returnTypes: [])

    // Update the Services menu
    NSUpdateDynamicServices()

    // Set frame autosave name for the main window and become its delegate
    DispatchQueue.main.async { [self] in
      if let window = NSApp.windows.first {
        window.setFrameAutosaveName("KokoroTTSMainWindow")
        window.delegate = self
        mainWindow = window
      }
    }

    // Set up menu bar icon
    setupStatusItem()

    // Apply saved dock visibility preference
    if UserDefaults.standard.bool(forKey: hideFromDockKey) {
      NSApp.setActivationPolicy(.accessory)
    }
  }

  // MARK: - Window Delegate

  func windowShouldClose(_ sender: NSWindow) -> Bool {
    if UserDefaults.standard.bool(forKey: hideFromDockKey) {
      sender.orderOut(nil)
      return false
    }
    return true
  }

  func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
    if !flag {
      showMainWindow()
    }
    return true
  }

  // MARK: - Menu Bar

  private func setupStatusItem() {
    statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)

    if let button = statusItem?.button {
      button.image = NSImage(systemSymbolName: "waveform", accessibilityDescription: "Kokoro TTS")
    }

    let menu = NSMenu()
    menu.delegate = self
    statusItem?.menu = menu
  }

  private func rebuildMenu(_ menu: NSMenu) {
    menu.removeAllItems()

    let showWindowItem = NSMenuItem(title: "Show Window", action: #selector(showMainWindow), keyEquivalent: "")
    showWindowItem.target = self
    menu.addItem(showWindowItem)

    menu.addItem(NSMenuItem.separator())

    let autoStartItem = NSMenuItem(title: "Launch at Login", action: #selector(toggleAutoStart(_:)), keyEquivalent: "")
    autoStartItem.target = self
    autoStartItem.state = isAutoStartEnabled() ? .on : .off
    menu.addItem(autoStartItem)

    let showInDockItem = NSMenuItem(title: "Show in Dock", action: #selector(toggleShowInDock(_:)), keyEquivalent: "")
    showInDockItem.target = self
    showInDockItem.state = UserDefaults.standard.bool(forKey: hideFromDockKey) ? .off : .on
    menu.addItem(showInDockItem)

    menu.addItem(NSMenuItem.separator())

    let exitItem = NSMenuItem(title: "Quit KokoroTTS", action: #selector(exitApp), keyEquivalent: "q")
    exitItem.target = self
    menu.addItem(exitItem)
  }

  func menuWillOpen(_ menu: NSMenu) {
    rebuildMenu(menu)
  }

  @objc private func showMainWindow() {
    guard let window = mainWindow else { return }

    if UserDefaults.standard.bool(forKey: hideFromDockKey) {
      // In accessory mode: show as floating window without changing policy
      window.level = .floating
      window.orderFrontRegardless()
      // Reset to normal level once it's visible so it behaves like a regular window
      DispatchQueue.main.async {
        window.level = .normal
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
      }
    } else {
      window.makeKeyAndOrderFront(nil)
      NSApp.activate(ignoringOtherApps: true)
    }
  }

  @objc private func toggleAutoStart(_ sender: NSMenuItem) {
    let enabled = !isAutoStartEnabled()
    setAutoStart(enabled: enabled)
    sender.state = enabled ? .on : .off
  }

  @objc private func toggleShowInDock(_ sender: NSMenuItem) {
    let currentlyHidden = UserDefaults.standard.bool(forKey: hideFromDockKey)
    let newHidden = !currentlyHidden
    UserDefaults.standard.set(newHidden, forKey: hideFromDockKey)
    sender.state = newHidden ? .off : .on

    if newHidden {
      NSApp.setActivationPolicy(.accessory)
    } else {
      NSApp.setActivationPolicy(.regular)
      // Show the window when returning to dock
      DispatchQueue.main.async { [self] in
        if let window = mainWindow {
          window.makeKeyAndOrderFront(nil)
        }
        NSApp.activate(ignoringOtherApps: true)
      }
    }
  }

  @objc private func exitApp() {
    NSApp.terminate(nil)
  }

  private func isAutoStartEnabled() -> Bool {
    // Check if login item is registered via SMAppService
    if #available(macOS 13.0, *) {
      return SMAppService.mainApp.status == .enabled
    }
    return false
  }

  private func setAutoStart(enabled: Bool) {
    if #available(macOS 13.0, *) {
      do {
        if enabled {
          try SMAppService.mainApp.register()
        } else {
          try SMAppService.mainApp.unregister()
        }
      } catch {
        print("Failed to \(enabled ? "enable" : "disable") auto-start: \(error)")
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

    // Extract text from pasteboard (tries RTF headline detection first, then plain text)
    guard let text = PasteboardHelper.extractText(from: pboard) else {
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
