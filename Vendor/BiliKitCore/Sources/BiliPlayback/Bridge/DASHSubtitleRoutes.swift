import BiliModels
import BiliNetworking
import Foundation

extension DASHToHLSBridge {
    /// master playlist 的 `_hls.localized-rendition-names` 会话数据：原声音轨与需要区分的字幕
    /// rendition 的多语言显示名（JSON），由系统按界面语言选用。
    func localizedRenditionNamesResource(
        audioTracks: [PlaybackAudioTrack],
        subtitleCatalog: [NativeSubtitleCatalogEntry]
    ) throws -> LoopbackPlaybackResource {
        var localizedNames: [String: [String: String]] = [:]
        for track in audioTracks where track.role == .original {
            localizedNames[track.displayName] = [
                "en": "Original audio",
                "ja": "オリジナル音声",
                "zh": "原声",
                "zh-Hans": "原声",
                "zh-Hant": "原聲"
            ]
        }
        let subtitleLanguageGroups = Dictionary(
            grouping: subtitleCatalog,
            by: { primaryLanguageSubtag($0.languageTag) }
        )
        for (language, languageEntries) in subtitleLanguageGroups
        where language != "und" {
            let translations = localizedLanguageNames(for: language)
            guard !translations.isEmpty else { continue }
            for entry in languageEntries
            where entry.characteristics.contains("public.machine-generated")
                && localizedNames[entry.label] == nil
            {
                // 系统会按 machine-generated 特征另加本地化标注，所以机器生成字幕的显示名换成
                // 语言本身的名称，源标签“中文（AI）”就不会显示成“中文（AI）（生成）”。
                localizedNames[entry.label] = translations
            }
        }
        // 同一语言里去掉“（AI）”后同名、特征组合又互不相同的多条字幕，也都换成语言名，
        // 彼此由系统按特征加的标注区分。
        for (language, languageEntries) in subtitleLanguageGroups
        where language != "und" && languageEntries.count > 1 {
            let labelGroups = Dictionary(
                grouping: languageEntries,
                by: { baseSubtitleLabel($0.label) }
            )
            for entries in labelGroups.values where entries.count > 1 {
                let characteristicSignatures = Set(
                    entries.map {
                        $0.characteristics.sorted().joined(separator: ",")
                    }
                )
                guard characteristicSignatures.count == entries.count else {
                    continue
                }
                let translations = localizedLanguageNames(for: language)
                guard !translations.isEmpty else { continue }
                for entry in entries where localizedNames[entry.label] == nil {
                    localizedNames[entry.label] = translations
                }
            }
        }
        let body = try JSONSerialization.data(
            withJSONObject: localizedNames,
            options: [.sortedKeys]
        )
        return .inMemory(
            data: body,
            contentType: "application/json; charset=utf-8"
        )
    }

    private func primaryLanguageSubtag(_ languageTag: String) -> String {
        languageTag.split(separator: "-", maxSplits: 1).first.map {
            String($0).lowercased()
        } ?? "und"
    }

    private func baseSubtitleLabel(_ label: String) -> String {
        let suffix = "（AI）"
        guard label.hasSuffix(suffix) else { return label }
        return String(label.dropLast(suffix.count))
    }

    private func localizedLanguageNames(
        for language: String
    ) -> [String: String] {
        var names: [String: String] = [:]
        for interfaceLanguage in ["en", "ja", "zh"] {
            if let name = Locale(identifier: interfaceLanguage)
                .localizedString(forLanguageCode: language)
            {
                names[interfaceLanguage] = name
            }
        }
        return names
    }

    /// 媒体索引就绪后最多再等 `subtitleCatalogGrace` 取字幕目录；超时或失败按无字幕起播，
    /// 只有调用方自身被取消时才抛出取消。
    func freezeCatalog(
        _ catalogTask: Task<[NativeSubtitleCatalogEntry], any Error>?
    ) async throws -> [NativeSubtitleCatalogEntry] {
        guard let catalogTask else { return [] }
        let relay = OneShotResult<[NativeSubtitleCatalogEntry]>()
        let observer = Task {
            do {
                relay.resolve(.success(try await catalogTask.value))
            } catch {
                relay.resolve(.failure(error))
            }
        }
        let timeout = Task {
            do {
                try await Task.sleep(for: Self.subtitleCatalogGrace)
                catalogTask.cancel()
                relay.resolve(
                    .failure(DASHToHLSBridgeError.subtitleCatalogTimedOut)
                )
            } catch is CancellationError {
                return
            } catch {
                relay.resolve(.failure(error))
            }
        }
        do {
            let result = try await withTaskCancellationHandler {
                try await relay.value()
            } onCancel: {
                catalogTask.cancel()
                relay.resolve(.failure(CancellationError()))
            }
            timeout.cancel()
            observer.cancel()
            return result
        } catch is CancellationError where Task.isCancelled {
            timeout.cancel()
            observer.cancel()
            catalogTask.cancel()
            throw CancellationError()
        } catch {
            timeout.cancel()
            observer.cancel()
            catalogTask.cancel()
            return []
        }
    }

    /// 为字幕目录的每一项登记 playlist 与按需生成的 WebVTT route；各档视频时间轴起点不一致时失败。
    func makeSubtitleRoutes(
        catalog: [NativeSubtitleCatalogEntry],
        source: NativeSubtitleSource?,
        videoIndices: [SegmentIndex],
        registrations: inout [LoopbackRouteRegistration],
        server: LoopbackPlaybackServer
    ) throws -> [HLSSubtitleRendition] {
        guard let source, !catalog.isEmpty else { return [] }
        guard let videoIndex = videoIndices.first,
            videoIndices.dropFirst().allSatisfy({
                hasMatchingSubtitleTimeline($0, canonical: videoIndex)
            })
        else {
            throw DASHToHLSBridgeError.inconsistentSubtitleTimeline
        }
        let duration =
            videoIndices.map { index in
                index.references.reduce(0.0) {
                    $0 + Double($1.duration) / Double(index.timescale)
                }
            }.max() ?? 0

        return try catalog.enumerated().map { offset, entry in
            let playlistPath = "subtitle/\(offset).m3u8"
            let bodyPath = "subtitle/generated/\(offset).vtt"
            let playlistURL = try server.url(for: playlistPath)
            let bodyURL = try server.url(for: bodyPath)
            // 生成的 WebVTT 不超过 2 MiB，与字幕正文的下载上限相同（见 SECURITY-MODEL §4）；
            // 超出时该字幕请求失败。
            let generated = try LoopbackGeneratedResource(
                contentType: "text/vtt; charset=utf-8",
                maximumContentLength: 2 * 1_024 * 1_024
            ) {
                let cues = try await source.cues(for: entry.trackID)
                return try webVTTEncoder.encode(
                    cues: cues,
                    earliestPresentationTime: videoIndex.earliestPresentationTime,
                    timescale: videoIndex.timescale
                )
            }
            let playlist = try subtitlePlaylistBuilder.build(
                segmentURI: bodyURL,
                duration: duration
            )
            registrations.append(
                LoopbackRouteRegistration(
                    relativePath: playlistPath,
                    resource: playlistResource(playlist)
                )
            )
            registrations.append(
                LoopbackRouteRegistration(
                    relativePath: bodyPath,
                    resource: .generated(generated)
                )
            )
            return HLSSubtitleRendition(
                name: entry.label,
                languageTag: entry.languageTag,
                characteristics: entry.characteristics,
                playlistURI: playlistURL
            )
        }
    }
}
