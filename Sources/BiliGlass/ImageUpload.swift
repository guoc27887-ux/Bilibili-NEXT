#if os(macOS)
import AppKit
#endif
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

struct UploadedImage {
  let url: String
  let width: Int
  let height: Int
  let bytes: Int
  var sizeKB: Double? = nil
  var commentPayload: [String: Any] { ["img_src": url, "img_width": width, "img_height": height, "img_size": sizeKB ?? Double(bytes) / 1024] }
  var messagePayload: [String: Any] { ["url": url, "width": width, "height": height, "size": bytes, "original": 1] }
}
#if os(macOS)
enum ImageAttachment {
  @MainActor static func choose(multiple: Bool = false) -> [URL] {
    let panel = NSOpenPanel(); panel.allowedContentTypes = [.jpeg, .png, .webP, .gif]
    panel.allowsMultipleSelection = multiple; panel.canChooseDirectories = false
    return panel.runModal() == .OK ? Array(panel.urls.prefix(multiple ? 9 : 1)) : []
  }
}
#endif
private struct LocalUploadImage: Sendable {
  let data: Data
  let mime: String
  let extensionName: String
  let width: Int
  let height: Int
  static func read(_ url: URL) throws -> Self {
    let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max
    guard size > 0, size <= 10 * 1024 * 1024 else { throw BiliError(text: "请选择 10 MB 以内的有效图片") }
    let data = try Data(contentsOf: url)
    guard data.count <= 10 * 1024 * 1024, let source = CGImageSourceCreateWithData(data as CFData, nil),
      let type = CGImageSourceGetType(source) as String?, let uti = UTType(type),
      [UTType.jpeg, .png, .webP, .gif].contains(where: { uti.conforms(to: $0) }), let mime = uti.preferredMIMEType,
      let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
      let width = properties[kCGImagePropertyPixelWidth] as? Int,
      let height = properties[kCGImagePropertyPixelHeight] as? Int, width > 0, height > 0,
      Int64(width) * Int64(height) <= 100_000_000 else { throw BiliError(text: "请选择 10 MB 以内的有效图片") }
    return Self(data: data, mime: mime, extensionName: uti.preferredFilenameExtension ?? "png", width: width, height: height)
  }
}
extension API {
  func uploadImage(_ url: URL, business: String) async throws -> UploadedImage {
    guard ["im", "new_dyn"].contains(business), signedIn, let csrf = cookies["bili_jct"] else { throw BiliError(text: "请先登录") }
    let auth = authenticationGeneration
    let image = try await Task.detached(priority: .userInitiated) { try LocalUploadImage.read(url) }.value
    try Task.checkCancellation()
    guard auth == authenticationGeneration else { throw CancellationError() }
    let boundary = "BiliNext-" + UUID().uuidString
    var body = Data()
    func append(_ text: String) { body.append(Data(text.utf8)) }
    var fields = ["biz": business, "csrf": csrf, "csrf_token": csrf]
    if business == "new_dyn" { fields["category"] = "daily" }
    for (key, value) in fields {
      append("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(key)\"\r\n\r\n\(value)\r\n")
    }
    append("--\(boundary)\r\nContent-Disposition: form-data; name=\"file_up\"; filename=\"image.\(image.extensionName)\"\r\nContent-Type: \(image.mime)\r\n\r\n")
    body.append(image.data); append("\r\n--\(boundary)--\r\n")
    var request = URLRequest(url: URL(string: "https://api.bilibili.com/x/dynamic/feed/draw/upload_bfs")!)
    request.httpMethod = "POST"; request.httpBody = body
    Self.mediaHeaders.forEach { request.setValue($1, forHTTPHeaderField: $0) }
    request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
    request.setValue("https://www.bilibili.com", forHTTPHeaderField: "Origin")
    request.setValue(cookies.map { "\($0.key)=\($0.value)" }.joined(separator: "; "), forHTTPHeaderField: "Cookie")
    let (responseData, response) = try await session.data(for: request)
    try Task.checkCancellation(); guard auth == authenticationGeneration else { throw CancellationError() }
    guard (response as? HTTPURLResponse)?.statusCode == 200,
      let root = try JSONSerialization.jsonObject(with: responseData) as? [String: Any],
      root["code"] as? Int == 0, let result = root["data"] as? [String: Any],
      let address = result["image_url"] as? String, let safe = Self.publicMediaURL(address) else { throw BiliError(text: "图片上传失败，请检查网络与账号权限") }
    return UploadedImage(url: safe.absoluteString, width: result["image_width"] as? Int ?? image.width,
      height: result["image_height"] as? Int ?? image.height, bytes: image.data.count, sizeKB: (result["img_size"] as? NSNumber)?.doubleValue)
  }
}
struct AttachedImages: View {
  @Binding var urls: [URL]
  var body: some View {
    ScrollView(.horizontal) {
      HStack(spacing: 10) { ForEach(urls, id: \.self) { url in
        HStack { Image(systemName: "photo"); Text(url.lastPathComponent).lineLimit(1); Button { urls.removeAll { $0 == url } } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.plain) }.padding(8).appGlass(10)
      } }
    }.frame(maxHeight: 45)
  }
}
