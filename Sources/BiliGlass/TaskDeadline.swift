import Foundation

func withDeadline<T: Sendable>(seconds: Double, operation: @escaping @Sendable () async throws -> T)
  async throws -> T
{
  try await withThrowingTaskGroup(of: T.self) { group in
    group.addTask { try await operation() }
    group.addTask {
      try await Task.sleep(for: .seconds(seconds))
      throw BiliError(text: "连接视频线路超时")
    }
    defer { group.cancelAll() }
    return try await group.next()!
  }
}
