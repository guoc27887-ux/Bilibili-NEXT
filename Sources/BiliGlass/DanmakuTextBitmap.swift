import CoreText

#if os(macOS)
  import AppKit
#else
  import UIKit
#endif

enum DanmakuTextBitmap {
  /// CATextLayer does not consistently honor AppKit's negative attributed stroke width.
  /// Draw both outline and fill into one bitmap; scrolling only moves the cached layer.
  static func make(text: String, fontSize: CGFloat, color: Int, size: CGSize, scale: CGFloat)
    -> CGImage?
  {
    let scale = max(1, scale)
    let width = Int(ceil(size.width * scale))
    let height = Int(ceil(size.height * scale))
    guard width > 0, height > 0, width <= 32768, height <= 1024,
      let context = CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { return nil }
    context.scaleBy(x: scale, y: scale)
    context.setShouldAntialias(true)
    context.setAllowsAntialiasing(true)
    #if os(macOS)
      let font = NSFont.systemFont(ofSize: fontSize, weight: .semibold)
    #else
      let font = UIFont.systemFont(ofSize: fontSize, weight: .semibold)
    #endif
    let string = NSAttributedString(
      string: text,
      attributes: [
        .font: font,
        NSAttributedString.Key(kCTForegroundColorFromContextAttributeName as String): true,
      ])
    let line = CTLineCreateWithAttributedString(string)
    let red = CGFloat((color >> 16) & 255) / 255
    let green = CGFloat((color >> 8) & 255) / 255
    let blue = CGFloat(color & 255) / 255
    let fill = CGColor(red: red, green: green, blue: blue, alpha: 1)
    let luminance = red * 0.2126 + green * 0.7152 + blue * 0.0722
    context.textPosition = CGPoint(x: 3, y: -font.descender + 2)
    context.setLineJoin(.round)
    context.setLineWidth(max(1.2, fontSize * 0.055))
    let outline: CGFloat = luminance < 0.16 ? 1 : 0
    context.setStrokeColor(CGColor(red: outline, green: outline, blue: outline, alpha: 0.95))
    context.setFillColor(fill)
    context.setTextDrawingMode(.fillStroke)
    CTLineDraw(line, context)
    // A second fill pass keeps thin glyph interiors fully opaque after the outline.
    context.setTextDrawingMode(.fill)
    context.textPosition = CGPoint(x: 3, y: -font.descender + 2)
    CTLineDraw(line, context)
    return context.makeImage()
  }
}
