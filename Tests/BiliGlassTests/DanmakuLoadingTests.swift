import Foundation
import Testing
@testable import BiliGlass

private final class SpecialPackageProtocol: URLProtocol, @unchecked Sendable {
  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
  override func stopLoading() {}
  override func startLoading() {
    let path = request.url!.path
    let failed = path == "/bad.bin"
    let response = HTTPURLResponse(url:request.url!,statusCode:failed ? 503 : 200,httpVersion:nil,
      headerFields:["Content-Type":"application/octet-stream"])!
    var bytes: [UInt8] = []
    if path == "/x/v2/dm/web/view" {
      for name in ["first","bad","last"] {
        let value = Array("https://i0.hdslb.com/\(name).bin".utf8)
        bytes += [50,UInt8(value.count)] + value
      }
    } else if !failed {
      let text = Array(path.utf8)
      let element = [UInt8(58),UInt8(text.count)] + text + [98,UInt8(text.count)] + text
      bytes = [10,UInt8(element.count)] + element
    }
    client?.urlProtocol(self,didReceive:response,cacheStoragePolicy:.notAllowed)
    client?.urlProtocol(self,didLoad:Data(bytes))
    client?.urlProtocolDidFinishLoading(self)
  }
}

@MainActor struct DanmakuLoadingTests {
  @Test func failedMiddlePackageKeepsEarlierDataAndStillLoadsLaterPackage() async {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [SpecialPackageProtocol.self]
    let api = API(loadCredentials:false,transport:URLSession(configuration:configuration))
    var received: [String] = []
    var progress: [Int] = []
    var failed = false
    do {
      _ = try await api.specialDanmaku(cid:1) { batch, count, total in
        #expect(total == 3)
        received += batch.map(\.text)
        progress.append(count)
      }
    } catch { failed = true }
    #expect(failed)
    #expect(received == ["/first.bin","/last.bin"])
    #expect(progress == [1,2,3])
  }
}
