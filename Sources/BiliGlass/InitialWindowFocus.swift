import SwiftUI

/// AppKit otherwise selects the first text field when a new window opens.
/// Keep the idle window out of text editing; explicit clicks and Command-F still focus search.
struct InitialWindowFocus: NSViewRepresentable {
  func makeNSView(context: Context) -> FocusAnchor { FocusAnchor() }
  func updateNSView(_ nsView: FocusAnchor, context: Context) {}
  final class FocusAnchor: NSView {
    private var handledFirstKey = false
    override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow()
      NotificationCenter.default.removeObserver(self)
      guard let window else { return }
      window.initialFirstResponder = nil
      NotificationCenter.default.addObserver(self, selector: #selector(becameKey),
        name: NSWindow.didBecomeKeyNotification, object: window)
      NotificationCenter.default.addObserver(self, selector: #selector(becameKey),
        name: NSApplication.didBecomeActiveNotification, object: nil)
      DispatchQueue.main.async { [weak self, weak window] in
        guard let self, let window, self.window === window else { return }
        window.makeFirstResponder(nil)
      }
    }
    @objc private func becameKey() {
      guard !handledFirstKey, NSApp.isActive, let window, window.isKeyWindow else { return }
      handledFirstKey = true
      // An explicit click into search must retain the user's focus.
      if let event = NSApp.currentEvent, event.type == .leftMouseDown,
        event.window === window, ProcessInfo.processInfo.systemUptime - event.timestamp < 0.2,
        let content = window.contentView {
        var hit = content.hitTest(content.convert(event.locationInWindow, from: nil))
        while let view = hit {
          if view is NSTextField { return }
          hit = view.superview
        }
      }
      DispatchQueue.main.async { [weak self] in self?.window?.makeFirstResponder(nil) }
    }
  }
}
