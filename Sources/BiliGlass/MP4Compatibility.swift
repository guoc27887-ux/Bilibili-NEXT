import CryptoKit
import Foundation

enum MP4Compatibility {
  /// Change only sample-entry tags with complete VPS/SPS/PPS in hvcC. Every box
  /// keeps its byte length, so media payloads and chunk offsets remain untouched.
  static func patchOffsets(_ url: URL) throws -> [UInt64] {
    let file = try FileHandle(forReadingFrom: url)
    defer { try? file.close() }
    let length = try file.seekToEnd()
    var offset: UInt64 = 0
    func uint(_ bytes: Data) -> UInt64 { bytes.reduce(0) { ($0 << 8) | UInt64($1) } }
    while offset + 8 <= length {
      try file.seek(toOffset: offset)
      guard let header = try file.read(upToCount: 8), header.count == 8 else { break }
      var size = uint(header.prefix(4))
      var headerSize: UInt64 = 8
      if size == 1 {
        guard let extended = try file.read(upToCount: 8), extended.count == 8 else { break }
        size = uint(extended); headerSize = 16
      } else if size == 0 { size = length - offset }
      guard size >= headerSize, size <= length - offset else { throw BiliError(text: "视频文件不完整") }
      if String(decoding: header.suffix(4), as: UTF8.self) == "moov" {
        guard size <= 16 * 1024 * 1024 else { throw BiliError(text: "视频轨道信息过大") }
        try file.seek(toOffset: offset)
        guard let moov = try file.read(upToCount: Int(size)), moov.count == Int(size) else { break }
        let info = try VideoSignalling.parse(moov)
        return info.hasHEVCParameterSets ? info.hevcSampleEntryOffsets.map { offset + UInt64($0) } : []
      }
      offset += size
    }
    return []
  }
  static func normalizeOwnedFile(_ url: URL) throws {
    let offsets = try patchOffsets(url)
    guard !offsets.isEmpty else { return }
    let file = try FileHandle(forWritingTo: url)
    defer { try? file.close() }
    for offset in offsets { try file.seek(toOffset: offset); try file.write(contentsOf: Data("hvc1".utf8)) }
    try file.synchronize()
  }
  static func playbackURL(_ original: URL) async throws -> URL {
    try await downloadIO {
      try Task.checkCancellation()
      guard !(try patchOffsets(original)).isEmpty else { return original }
      let attributes = try FileManager.default.attributesOfItem(atPath: original.path)
      let identity = "\(original.path)|\(attributes[.size] ?? 0)|\(attributes[.modificationDate] ?? "")"
      let name = SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined()
      let folder = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("BiliGlass/CompatibleMedia", isDirectory: true)
      try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
      let destination = folder.appendingPathComponent(name + ".mp4")
      if FileManager.default.fileExists(atPath: destination.path) { return destination }
      let partial = folder.appendingPathComponent(UUID().uuidString + ".partial")
      defer { try? FileManager.default.removeItem(at: partial) }
      try FileManager.default.copyItem(at: original, to: partial)
      try normalizeOwnedFile(partial)
      try Task.checkCancellation()
      try FileManager.default.moveItem(at: partial, to: destination)
      // This directory contains only disposable, app-created compatibility copies.
      let files = (try? FileManager.default.contentsOfDirectory(at: folder,
        includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
      let old = files.filter { $0 != destination && $0.pathExtension == "mp4" }.sorted {
        ((try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) >
        ((try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast)
      }
      for file in old.dropFirst(1) { try? FileManager.default.removeItem(at: file) }
      return destination
    }
  }
}
