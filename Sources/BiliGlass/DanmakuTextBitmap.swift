import AppKit
import CoreText

enum DanmakuTextBitmap {
  /// CATextLayer does not consistently honor AppKit's negative attributed stroke width.
  /// Draw both outline and fill into one bitmap; scrolling only moves the cached layer.
  static func make(text: String, fontSize: CGFloat, color: Int, size: CGSize, scale: CGFloat) -> CGImage? {
    let scale = max(1, scale)
    let width = Int(ceil(size.width * scale)), height = Int(ceil(size.height * scale))
    guard width > 0, height > 0, width <= 32768, height <= 1024,
      let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
    context.scaleBy(x: scale, y: scale)
    let font = NSFont.systemFont(ofSize: fontSize, weight: .semibold)
    let string = NSAttributedString(string: text, attributes: [
      .font: font, NSAttributedString.Key(kCTForegroundColorFromContextAttributeName as String): true,
    ])
    let line = CTLineCreateWithAttributedString(string)
    let fill = SpecialDanmakuRenderer.color(color)
    let luminance = fill.redComponent * 0.2126 + fill.greenComponent * 0.7152 + fill.blueComponent * 0.0722
    context.textPosition = CGPoint(x: 3, y: -font.descender + 2)
    context.setLineJoin(.round)
    context.setLineWidth(max(1.2, fontSize * 0.055))
    context.setStrokeColor((luminance < 0.16 ? NSColor.white : NSColor.black).withAlphaComponent(0.95).cgColor)
    context.setFillColor(fill.cgColor)
    context.setTextDrawingMode(.fillStroke)
    CTLineDraw(line, context)
    // A second fill pass keeps thin glyph interiors fully opaque after the outline.
    context.setTextDrawingMode(.fill)
    context.textPosition = CGPoint(x: 3, y: -font.descender + 2)
    CTLineDraw(line, context)
    return context.makeImage()
  }
}
