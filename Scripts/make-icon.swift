import AppKit
import ImageIO

// swift Scripts/make-icon.swift Assets/Bilibili-NEXT-icon.png /tmp/Bilibili-NEXT.iconset
// iconutil -c icns /tmp/Bilibili-NEXT.iconset -o Scripts/AppIcon.icns
precondition(CommandLine.arguments.count == 3, "Expected master PNG and output .iconset directory")
let sourceURL = URL(fileURLWithPath: CommandLine.arguments[1])
let folder = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
guard let source = CGImageSourceCreateWithURL(sourceURL as CFURL, nil),
      let original = CGImageSourceCreateImageAtIndex(source, 0, nil) else { fatalError("Cannot decode icon master") }
try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
for size in [16, 32, 64, 128, 256, 512, 1024] {
  let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
  let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8,
    bytesPerRow: size * 4, space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
  context.interpolationQuality = .high
  context.draw(original, in: CGRect(x: 0, y: 0, width: size, height: size))
  let bitmap = NSBitmapImageRep(cgImage: context.makeImage()!)
  let data = bitmap.representation(using: .png, properties: [:])!
  let names: [String]
  switch size {
  case 16: names = ["icon_16x16.png"]
  case 32: names = ["icon_16x16@2x.png", "icon_32x32.png"]
  case 64: names = ["icon_32x32@2x.png"]
  case 128: names = ["icon_128x128.png"]
  case 256: names = ["icon_128x128@2x.png", "icon_256x256.png"]
  case 512: names = ["icon_256x256@2x.png", "icon_512x512.png"]
  default: names = ["icon_512x512@2x.png"]
  }
  for name in names { try data.write(to: folder.appendingPathComponent(name)) }
}
