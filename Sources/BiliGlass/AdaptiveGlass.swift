import SwiftUI

/// iOS 18 back-deployment adapters for Liquid Glass.
///
/// Liquid Glass (`glassEffect`, `.glass` button styles, `GlassEffectContainer`)
/// exists only on iOS 26+ / macOS 26+. These adapters keep the existing
/// call-site spelling and render the real glass on 26+, while falling back
/// to regular materials and bordered styles below that, so the app compiles
/// and runs with a deployment target of iOS 18. Behaviour on iOS 26+ and
/// macOS 26+ is unchanged.
///
/// This file is part of both the macOS target and the iOS target (it is
/// registered in `Apps/iOS/BilibiliNEXT.xcodeproj`), so every call site below
/// resolves on both platforms.

/// Platform-safe stand-in for SwiftUI's `Glass` value (iOS 26+ only).
/// It stores only plain values, so it can be named from code compiled for
/// iOS 18; the conversion back to a real `Glass` happens inside the
/// availability-gated branch of `adaptiveGlassEffect(_:in:)`.
struct AdaptiveGlass {
  enum Base { case regular, clear }
  var base: Base
  var tint: Color?
  var interactive: Bool

  static let regular = AdaptiveGlass(base: .regular, tint: nil, interactive: false)
  static let clear = AdaptiveGlass(base: .clear, tint: nil, interactive: false)

  func tint(_ color: Color) -> AdaptiveGlass {
    var copy = self
    copy.tint = color
    return copy
  }

  func interactive(_ enabled: Bool = true) -> AdaptiveGlass {
    var copy = self
    copy.interactive = enabled
    return copy
  }
}

extension View {
  /// Drop-in replacement for `.glassEffect(_:in:)` that also works on iOS 18.
  /// Below iOS 26 / macOS 26 the glass becomes a regular material background
  /// in the same shape.
  @ViewBuilder
  func adaptiveGlassEffect(_ glass: AdaptiveGlass, in shape: some Shape) -> some View {
    if #available(iOS 26, macOS 26, *) {
      switch glass.base {
      case .regular:
        if let tint = glass.tint {
          if glass.interactive {
            glassEffect(.regular.tint(tint).interactive(), in: shape)
          } else {
            glassEffect(.regular.tint(tint), in: shape)
          }
        } else if glass.interactive {
          glassEffect(.regular.interactive(), in: shape)
        } else {
          glassEffect(.regular, in: shape)
        }
      case .clear:
        glassEffect(.clear, in: shape)
      }
    } else {
      background(.ultraThinMaterial, in: shape)
    }
  }

  /// Drop-in replacement for `.buttonStyle(.glass)` /
  /// `.buttonStyle(.glassProminent)` that also works on iOS 18.
  /// Below iOS 26 / macOS 26 the glass styles become the bordered styles;
  /// `tint`, `controlSize` and other modifiers in the chain are untouched.
  @ViewBuilder
  func adaptiveGlassButtonStyle(prominent: Bool = false) -> some View {
    if #available(iOS 26, macOS 26, *) {
      if prominent {
        buttonStyle(.glassProminent)
      } else {
        buttonStyle(.glass)
      }
    } else {
      if prominent {
        buttonStyle(.borderedProminent)
      } else {
        buttonStyle(.bordered)
      }
    }
  }
}

/// Drop-in replacement for `GlassEffectContainer` that also works on iOS 18.
/// Every current call site wraps a single child view (the container only
/// groups glass effects; layout belongs to the child), so below iOS 26 /
/// macOS 26 the child is rendered as-is.
struct AdaptiveGlassEffectContainer<Content: View>: View {
  var spacing: CGFloat
  var content: Content

  init(spacing: CGFloat = 0, @ViewBuilder content: () -> Content) {
    self.spacing = spacing
    self.content = content()
  }

  var body: some View {
    if #available(iOS 26, macOS 26, *) {
      GlassEffectContainer(spacing: spacing) { content }
    } else {
      content
    }
  }
}
