import AppKit
import Testing
@testable import BiliGlass

struct DanmakuBitmapTests {
  @Test func outlinedTextHasSolidInteriorsAndContrastingEdges() throws {
    let image = try #require(DanmakuTextBitmap.make(text:"田中 Ag",fontSize:25,color:0xFFFFFF,
      size:CGSize(width:160,height:40),scale:2))
    let bitmap = NSBitmapImageRep(cgImage:image)
    var white = 0, dark = 0
    for y in 0..<bitmap.pixelsHigh {
      for x in 0..<bitmap.pixelsWide {
        guard let color = bitmap.colorAt(x:x,y:y)?.usingColorSpace(.deviceRGB), color.alphaComponent > 0.9 else { continue }
        if color.redComponent > 0.9 { white += 1 }
        if color.redComponent < 0.1 { dark += 1 }
      }
    }
    #expect(white > 500)
    #expect(dark > 100)
  }
}
