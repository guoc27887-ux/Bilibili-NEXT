import SwiftUI

/// Give AppKit a neutral initial responder without changing focus after a user's click.
struct InitialWindowFocus: NSViewRepresentable {
  func makeNSView(context: Context) -> FocusAnchor { FocusAnchor() }
  func updateNSView(_ nsView: FocusAnchor, context: Context) {}
  final class FocusAnchor: NSView {
    override var acceptsFirstResponder: Bool { true }
    override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow()
      window?.initialFirstResponder = self
    }
  }
}
