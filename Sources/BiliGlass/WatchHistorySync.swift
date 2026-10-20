import Foundation
import Observation

/// Reports actual viewing only. Old device history is displayed locally, never replayed as views.
@MainActor @Observable final class WatchHistorySync {
  private(set) var error: String?
  private(set) var syncing = false
  private struct Progress {
    let aid: Int
    let bvid: String
    let cid: Int
    let seconds: Int
    var key: String { "\(bvid):\(cid)" }
  }
  private var pending: [Progress] = []
  private var lastAttempt: [String: Date] = [:]
  private var confirmed: [String: Int] = [:]
  private var task: Task<Void, Never>?
  private var generation = UUID()
  private var authentication: UUID?
  private let enabled: () -> Bool
  init(enabled: @escaping () -> Bool = {
    UserDefaults.standard.object(forKey: "syncWatchHistory") as? Bool ?? true
  }) { self.enabled = enabled }

  func reset() {
    generation = UUID(); task?.cancel(); task = nil; authentication = nil
    pending = []; lastAttempt = [:]; confirmed = [:]; syncing = false; error = nil
  }
  func record(api: API, aid: Int, bvid: String, cid: Int, seconds: Double,
              final: Bool = false, now: Date = Date()) {
    if authentication != api.authenticationGeneration { reset(); authentication = api.authenticationGeneration }
    guard enabled(), api.signedIn else { reset(); return }
    guard aid > 0, cid > 0, seconds.isFinite, seconds > 0, seconds < Double(Int.max) else { return }
    let progress = Progress(aid: aid, bvid: bvid, cid: cid, seconds: Int(seconds))
    if !final, let previous = lastAttempt[progress.key], now.timeIntervalSince(previous) < 30 { return }
    guard confirmed[progress.key] != progress.seconds || task != nil else { return }
    lastAttempt[progress.key] = now
    // Keep the latest position per episode, with at most one request in flight.
    pending.removeAll { $0.key == progress.key }
    pending.append(progress)
    guard task == nil else { return }
    let token = generation, auth = api.authenticationGeneration
    syncing = true
    task = Task { [weak self] in
      guard let self else { return }
      while !self.pending.isEmpty {
        guard !Task.isCancelled, token == self.generation, auth == api.authenticationGeneration,
          self.enabled(), api.signedIn else {
          if token == self.generation { self.reset() }
          return
        }
        let item = self.pending.removeFirst()
        if self.confirmed[item.key] == item.seconds { continue }
        do {
          _ = try await api.post("/x/v2/history/report",
            ["aid": "\(item.aid)", "cid": "\(item.cid)", "progress": "\(item.seconds)"],
            videoBVID: item.bvid)
          try Task.checkCancellation()
          guard token == self.generation, auth == api.authenticationGeneration else { break }
          self.confirmed[item.key] = item.seconds; self.error = nil
        } catch {
          guard token == self.generation, auth == api.authenticationGeneration else { break }
          if !(error is CancellationError) { self.error = "观看进度暂未同步：\(error.localizedDescription)" }
        }
      }
      guard token == self.generation else { return }
      self.syncing = false; self.task = nil
    }
  }
}
