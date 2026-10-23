#if DEBUG
  import Foundation

  /// Opt-in UI test transport: all requests stay local, without account mutations.
  final class MobileFavoriteFixture: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    private static var saved = false
    static var enabled: Bool { ProcessInfo.processInfo.arguments.contains("--qa-favorite-form") }
    @MainActor static func makeAPI() -> API {
      let configuration = URLSessionConfiguration.ephemeral
      configuration.protocolClasses = [MobileFavoriteFixture.self]
      let api = API(loadCredentials: false, transport: URLSession(configuration: configuration))
      api.cookies = [
        "SESSDATA": "local-fixture", "bili_jct": "local-fixture", "buvid3": "local-fixture",
      ]
      return api
    }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
      Self.lock.lock()
      defer { Self.lock.unlock() }
      let path = request.url?.path ?? ""
      let data: [String: Any]
      if path == "/x/v3/fav/resource/deal", request.httpMethod == "POST" {
        var body = request.httpBody ?? Data()
        if let stream = request.httpBodyStream {
          stream.open()
          var buffer = [UInt8](repeating: 0, count: 4096)
          while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count <= 0 { break }
            body.append(contentsOf: buffer.prefix(count))
          }
          stream.close()
        }
        let values =
          URLComponents(
            string: "https://fixture.invalid/?" + String(decoding: body, as: UTF8.self))?.queryItems
          ?? []
        Self.saved = values.contains { $0.name == "add_media_ids" && $0.value == "1" }
        data = [:]
      } else if path == "/x/v3/fav/folder/created/list-all" {
        data = [
          "list": (1...28).map { id in
            [
              "id": id, "title": "测试收藏夹 \(id)", "media_count": 3,
              "fav_state": id == 1 && Self.saved ? 1 : 0,
              "attr": id == 1 ? 3 : 2,
            ] as [String: Any]
          }
        ]
      } else if path == "/x/web-interface/archive/relation" {
        data = ["like": false, "coin": 0, "favorite": Self.saved]
      } else {
        data = [:]
      }
      let response = HTTPURLResponse(
        url: request.url!, statusCode: 200, httpVersion: nil,
        headerFields: ["Content-Type": "application/json"])!
      client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
      client?.urlProtocol(
        self,
        didLoad: (try? JSONSerialization.data(withJSONObject: ["code": 0, "data": data])) ?? Data())
      client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
  }
#endif
