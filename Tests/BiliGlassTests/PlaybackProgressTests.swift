import Testing
@testable import BiliGlass

struct PlaybackProgressTests {
  @Test func slowVideoMayContinueButMissingVideoAndEndlessReadsExpire() {
    var slow = PlaybackProgressDeadline()
    let result6 = !slow.expired(now: .seconds(8), videoBytes: 100_000)
    #expect(result6)
    let result7 = !slow.expired(now: .seconds(18), videoBytes: 200_000)
    #expect(result7)
    let result8 = !slow.expired(now: .seconds(28), videoBytes: 300_000)
    #expect(result8)
    let result9 = slow.expired(now: .seconds(40), videoBytes: 300_000)
    #expect(result9)
    var empty = PlaybackProgressDeadline()
    let result11 = empty.expired(now: .seconds(12), videoBytes: 0)
    #expect(result11)
    var endless = PlaybackProgressDeadline()
    for second in 1..<45 {
      let result14 = !endless.expired(now: .seconds(second), videoBytes: second)
      #expect(result14)
    }
    let result16 = endless.expired(now: .seconds(45), videoBytes: 45)
    #expect(result16)
  }
}
