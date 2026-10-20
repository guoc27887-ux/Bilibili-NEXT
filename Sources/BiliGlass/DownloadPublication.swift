import CryptoKit
import Foundation

/// A checkpoint is written only after muxing and media validation have succeeded.
struct PreparedDownload: Codable, Sendable {
  let quality: String
  let digest: String
  let byteCount: Int64
}

enum DownloadPublication {
  static func checkpoint(_ folder: URL) -> URL { folder.appendingPathComponent("prepared.json") }

  static func prepare(_ output: URL, quality: String) throws -> PreparedDownload {
    let result = PreparedDownload(quality: quality, digest: try digest(output),
      byteCount: try size(output))
    try JSONEncoder().encode(result).write(to: checkpoint(output.deletingLastPathComponent()), options: .atomic)
    return result
  }

  static func restore(_ output: URL) throws -> PreparedDownload? {
    guard let data = try? Data(contentsOf: checkpoint(output.deletingLastPathComponent())),
      let result = try? JSONDecoder().decode(PreparedDownload.self, from: data),
      (try? size(output)) == result.byteCount else { return nil }
    return try digest(output) == result.digest ? result : nil
  }

  /// Never overwrite a different file. A prior successful publish is a successful retry.
  static func publish(_ output: URL, to requested: URL, prepared: PreparedDownload) throws -> URL {
    let fm = FileManager.default
    let partial = requested.deletingLastPathComponent().appendingPathComponent(".\(UUID()).partial")
    defer { try? fm.removeItem(at: partial) }
    var copied = false
    for suffix in 0..<10_000 {
      try Task.checkCancellation()
      let target = suffix == 0 ? requested : requested.deletingLastPathComponent()
        .appendingPathComponent(requested.deletingPathExtension().lastPathComponent + " (\(suffix + 1)).mp4")
      if fm.fileExists(atPath: target.path) {
        if (try? size(target)) == prepared.byteCount, (try? digest(target)) == prepared.digest { return target }
        continue
      }
      if !copied { try fm.copyItem(at: output, to: partial); copied = true }
      try Task.checkCancellation()
      do {
        try fm.moveItem(at: partial, to: target)
        return target
      } catch let error as CocoaError where error.code == .fileWriteFileExists {
        // Another publisher claimed this name between the check and rename.
        continue
      }
    }
    throw BiliError(text: "同名文件过多，请选择其他下载目录")
  }

  static func size(_ url: URL) throws -> Int64 {
    let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
    guard values.isRegularFile == true, values.isSymbolicLink != true, let size = values.fileSize, size > 0 else {
      throw BiliError(text: "下载文件不完整")
    }
    return Int64(size)
  }

  /// Re-exporting identical tracks changes only MP4 creation/modification timestamps.
  /// Ignore those defined fields, but compare all payload, codec and sample-table bytes.
  static func digest(_ url: URL) throws -> String {
    let length = try size(url)
    let reader = try FileHandle(forReadingFrom: url)
    defer { try? reader.close() }
    var hash = SHA256()
    var offset: Int64 = 0
    while offset < length {
      try Task.checkCancellation()
      try reader.seek(toOffset: UInt64(offset))
      let header = try reader.read(upToCount: 16) ?? Data()
      let size32 = integer(header, at: 0, count: 4)
      let boxLength = size32 == 1 ? integer(header, at: 8, count: 8) : size32
      let remaining = length - offset
      let validBox = header.count >= 8 && boxLength >= (size32 == 1 ? 16 : 8) && boxLength <= UInt64(remaining)
      let count = validBox ? Int64(boxLength) : remaining
      try reader.seek(toOffset: UInt64(offset))
      if validBox, header.subdata(in: 4..<8) == Data("moov".utf8), count <= 32 * 1024 * 1024 {
        var bytes = try reader.read(upToCount: Int(count)) ?? Data()
        guard Int64(bytes.count) == count else { throw BiliError(text: "下载文件读取不完整") }
        normalizeDates(&bytes, start: size32 == 1 ? 16 : 8, end: bytes.count)
        hash.update(data: bytes)
      } else {
        var left = count
        while left > 0 {
          try Task.checkCancellation()
          let bytes = try reader.read(upToCount: Int(min(left, 1024 * 1024))) ?? Data()
          guard !bytes.isEmpty else { throw BiliError(text: "下载文件读取不完整") }
          hash.update(data: bytes); left -= Int64(bytes.count)
        }
      }
      offset += count
    }
    return hash.finalize().map { String(format: "%02x", $0) }.joined()
  }

  private static func integer(_ data: Data, at offset: Int, count: Int) -> UInt64 {
    guard offset >= 0, offset + count <= data.count else { return 0 }
    return data[offset..<offset + count].reduce(0) { ($0 << 8) | UInt64($1) }
  }
  private static func normalizeDates(_ data: inout Data, start: Int, end: Int, depth: Int = 0) {
    guard depth < 4 else { return }
    var offset = start
    while offset + 8 <= end {
      let short = integer(data, at: offset, count: 4)
      let length = short == 1 ? integer(data, at: offset + 8, count: 8) : short
      let header = short == 1 ? 16 : 8
      guard length >= UInt64(header), length <= UInt64(end - offset) else { return }
      let boxEnd = offset + Int(length), payload = offset + header
      let kind = String(decoding: data[offset + 4..<offset + 8], as: UTF8.self)
      if ["mvhd", "tkhd", "mdhd"].contains(kind), payload + 4 <= boxEnd, data[payload] <= 1 {
        let count = data[payload] == 1 ? 16 : 8
        if payload + 4 + count <= boxEnd {
          data.replaceSubrange(payload + 4..<payload + 4 + count, with: repeatElement(UInt8(0), count: count))
        }
      } else if ["trak", "mdia"].contains(kind) {
        normalizeDates(&data, start: payload, end: boxEnd, depth: depth + 1)
      }
      offset = boxEnd
    }
  }
}
