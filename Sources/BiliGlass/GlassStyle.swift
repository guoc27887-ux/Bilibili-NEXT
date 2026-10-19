import SwiftUI
import ImageIO
import UniformTypeIdentifiers

extension View {
  func floatingGlass(_ radius: CGFloat = 22) -> some View { modifier(GlassSurface(radius: radius)) }
  func appAppearance() -> some View { modifier(AppAppearance()) }
  func cardHover() -> some View { modifier(CardHover()) }
}
private struct GlassSurface: ViewModifier {
  let radius: CGFloat
  @AppStorage("glassStyle") private var style = "clear"
  @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
  func body(content: Content) -> some View {
    content.glassEffect((style == "clear" && !reduceTransparency ? Glass.clear : Glass.regular)
      .tint(.primary.opacity(0.035)), in: .rect(cornerRadius: radius))
      .shadow(color: .black.opacity(0.12), radius: 16, y: 6)
  }
}
private struct AppAppearance: ViewModifier {
  @AppStorage("appearance") private var appearance = "dark"
  func body(content: Content) -> some View {
    content.preferredColorScheme(appearance == "system" ? nil : appearance == "light" ? .light : .dark)
  }
}
private struct CardHover: ViewModifier {
  @State private var hovering = false
  @AppStorage("interfaceAnimations") private var animations = true
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  func body(content: Content) -> some View {
    content.scaleEffect(hovering && animations && !reduceMotion ? 1.012 : 1)
      .animation(animations && !reduceMotion ? .smooth(duration: 0.18) : nil, value: hovering)
      .onHover { hovering = $0 }
  }
}
struct GlassBackdrop: View {
  @Environment(\.colorScheme) private var scheme
  @AppStorage("backgroundImage") private var path = ""
  @AppStorage("backgroundBlur") private var blur = false
  @AppStorage("backgroundOpacity") private var opacity = 0.7
  @State private var image: NSImage?
  var body: some View {
    GeometryReader { geometry in
      ZStack {
        LinearGradient(colors: scheme == .dark ? [Color(red: 0.025, green: 0.05, blue: 0.09), Color(red: 0.13, green: 0.20, blue: 0.28)] :
          [Color(red: 0.94, green: 0.96, blue: 0.99), Color(red: 0.79, green: 0.85, blue: 0.92)],
          startPoint: .topLeading, endPoint: .bottomTrailing)
        RadialGradient(colors: [.cyan.opacity(scheme == .dark ? 0.12 : 0.13), .clear],
                       center: .bottomLeading, startRadius: 30, endRadius: 850)
        RadialGradient(colors: [biliPink.opacity(0.12), .clear], center: .topTrailing, startRadius: 0, endRadius: 650)
        if let image, !path.isEmpty {
          Image(nsImage: image).resizable().scaledToFill()
            .frame(width: geometry.size.width, height: geometry.size.height).clipped()
            .blur(radius: blur ? 22 : 0).opacity(opacity)
          (scheme == .dark ? Color.black : Color.white).opacity(scheme == .dark ? 0.18 : 0.25)
        }
      }.frame(width: geometry.size.width, height: geometry.size.height).clipped()
    }.ignoresSafeArea().allowsHitTesting(false).task(id: path) {
      image = nil
      guard !path.isEmpty, let decoded = try? await BackgroundImages.shared.load(URL(fileURLWithPath: path)), !Task.isCancelled else { return }
      image = NSImage(cgImage: decoded, size: .zero)
    }
  }
}
actor BackgroundImages {
  static let shared = BackgroundImages()
  private var cached: (URL, CGImage)?
  func load(_ url: URL) throws -> CGImage {
    if let cached, cached.0 == url { return cached.1 }
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
      let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
        kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
        kCGImageSourceThumbnailMaxPixelSize: 3200, kCGImageSourceShouldCacheImmediately: true,
      ] as CFDictionary) else { throw BiliError(text: "无法读取这张背景图片") }
    cached = (url, image)
    return image
  }
  func importImage(_ original: URL) throws -> URL {
    let image = try load(original)
    let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("BiliGlass/Appearance")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let url = folder.appendingPathComponent(UUID().uuidString + ".png")
    guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
      throw BiliError(text: "无法保存背景图片")
    }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else { throw BiliError(text: "无法保存背景图片") }
    cached = (url, image)
    return url
  }
}
