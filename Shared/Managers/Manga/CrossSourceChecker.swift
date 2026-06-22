//
//  CrossSourceChecker.swift
//  Aidoku
//
//  Checks whether another installed source has newer chapters for a library
//  manga than the source it's currently read from.
//
//  Design goals (rebuilt to fix the previous version's problems):
//    - never interrupt the user: all requests run non-interactively, so a
//      Cloudflare challenge fails fast and the source is skipped instead of
//      showing a verification popup
//    - fast in steady state: once a title is matched on another source the
//      match is remembered, so later checks query only that source instead of
//      searching every installed source
//    - polite: bounded concurrency, jittered throttle, 6h result cache, and
//      automatic backoff for sources that keep failing or challenging
//

import AidokuRunner
import Foundation

/// Result of comparing a library manga against other installed sources.
struct CrossSourceResult: Codable, Sendable, Hashable {
    let sourceKey: String
    let mangaKey: String

    var matchedSourceKey: String?
    var matchedMangaKey: String?
    var matchedSourceName: String?

    /// Highest chapter number found on the matched source.
    var latestChapter: Float?
    /// Highest chapter number currently stored locally (i.e. the current source).
    var currentChapter: Float?

    var checkedAt: Date

    var uniqueKey: String { "\(sourceKey).\(mangaKey)" }

    var hasNewerSource: Bool {
        guard
            let latestChapter,
            let matchedSourceKey,
            matchedSourceKey != sourceKey
        else { return false }
        return latestChapter > (currentChapter ?? 0) + 0.0001
    }
}

actor CrossSourceChecker {
    static let shared = CrossSourceChecker()

    private struct MatchRef: Codable {
        let sourceKey: String
        let mangaKey: String
        let sourceName: String
    }

    private struct Backoff: Codable {
        var until: Date
        var failures: Int
    }

    private struct PersistedState: Codable {
        var results: [String: CrossSourceResult] = [:]
        var matches: [String: MatchRef] = [:]
        var backoff: [String: Backoff] = [:]
    }

    private var state = PersistedState()
    private var runningCheck: Task<Void, Never>?

    private let ttl: TimeInterval = 6 * 60 * 60
    private let maxConcurrent = 8

    private static var cacheFileURL: URL {
        FileManager.default.applicationSupportDirectory
            .appendingPathComponent("cross-source-cache.json")
    }

    init() {
        loadFromDisk()
    }

    // MARK: - Settings

    static var isEnabled: Bool {
        UserDefaults.standard.object(forKey: "CrossSource.enabled") as? Bool ?? true
    }

    private var excludedSources: Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: "CrossSource.excludedSources") ?? [])
    }

    // MARK: - Public API

    /// Cached result for a manga, if still within the TTL.
    func cachedResult(sourceKey: String, mangaKey: String) -> CrossSourceResult? {
        let result = state.results["\(sourceKey).\(mangaKey)"]
        guard let result, !isExpired(result) else { return nil }
        return result
    }

    /// Unique keys (`sourceKey.mangaKey`) of cached results that have a newer source.
    func newerSourceKeys() -> Set<String> {
        Set(
            state.results.values
                .filter { !isExpired($0) && $0.hasNewerSource }
                .map { $0.uniqueKey }
        )
    }

    /// Check a single manga, returning the (possibly cached) result.
    @discardableResult
    func check(
        sourceKey: String,
        mangaKey: String,
        title: String?,
        force: Bool = false
    ) async -> CrossSourceResult? {
        guard Self.isEnabled else { return nil }

        if !force, let cached = cachedResult(sourceKey: sourceKey, mangaKey: mangaKey) {
            return cached
        }

        let result = await performCheck(sourceKey: sourceKey, mangaKey: mangaKey, title: title)
        if let result {
            state.results[result.uniqueKey] = result
            persist()
            await postResult(result)
        }
        return result
    }

    /// Check the whole library. `manga` is the current library contents.
    func checkLibrary(_ manga: [MangaInfo], force: Bool = false) async {
        guard Self.isEnabled else { return }

        runningCheck?.cancel()
        let task = Task {
            await runLibraryCheck(manga, force: force)
        }
        runningCheck = task
        await task.value
        runningCheck = nil
    }

    func clearCache() {
        state = PersistedState()
        persist()
    }

    // MARK: - Library sweep

    private func runLibraryCheck(_ manga: [MangaInfo], force: Bool) async {
        await SourceManager.shared.waitForSourcesLoad()

        // skip anything still fresh in the cache
        let pending = manga.filter { info in
            force || cachedResult(sourceKey: info.sourceId, mangaKey: info.mangaId) == nil
        }
        guard !pending.isEmpty else {
            await postCompleted()
            return
        }

        await withTaskGroup(of: CrossSourceResult?.self) { group in
            var index = 0
            let limit = min(maxConcurrent, pending.count)

            while index < limit {
                let info = pending[index]
                index += 1
                group.addTask {
                    await self.performCheck(
                        sourceKey: info.sourceId,
                        mangaKey: info.mangaId,
                        title: info.title
                    )
                }
            }

            while let result = await group.next() {
                if let result = result.flatMap({ $0 }) {
                    state.results[result.uniqueKey] = result
                    await postResult(result)
                }
                if !Task.isCancelled, index < pending.count {
                    let info = pending[index]
                    index += 1
                    group.addTask {
                        await self.performCheck(
                            sourceKey: info.sourceId,
                            mangaKey: info.mangaId,
                            title: info.title
                        )
                    }
                }
            }
        }

        persist()
        await postCompleted()
    }

    // MARK: - Single check

    private func performCheck(
        sourceKey: String,
        mangaKey: String,
        title: String?
    ) async -> CrossSourceResult? {
        guard let title, !title.isEmpty else { return nil }

        let currentChapter = await localLatestChapter(sourceKey: sourceKey, mangaKey: mangaKey)

        var result = CrossSourceResult(
            sourceKey: sourceKey,
            mangaKey: mangaKey,
            checkedAt: Date()
        )

        // try the remembered match first, then fall back to discovery
        let uniqueKey = "\(sourceKey).\(mangaKey)"
        if
            let match = state.matches[uniqueKey],
            let source = SourceManager.shared.source(for: match.sourceKey),
            !isSourceSkipped(match.sourceKey)
        {
            let stub = AidokuRunner.Manga(sourceKey: match.sourceKey, key: match.mangaKey, title: "")
            if let latest = await fetchLatestChapter(source: source, manga: stub) {
                result.matchedSourceKey = match.sourceKey
                result.matchedMangaKey = match.mangaKey
                result.matchedSourceName = match.sourceName
                result.latestChapter = latest
                result.currentChapter = currentChapter
                return result
            } else {
                // remembered match no longer resolves; forget it and rediscover
                state.matches[uniqueKey] = nil
            }
        }

        // discovery: search other installed sources by title
        let candidates = candidateSources(excluding: sourceKey)
        let normalizedQuery = normalize(title)

        for source in candidates {
            if Task.isCancelled { break }
            await throttle()

            let entries: [AidokuRunner.Manga]
            do {
                let search = try await SourceRequestContext.$nonInteractive.withValue(true) {
                    try await source.getSearchMangaList(query: title, page: 1, filters: [])
                }
                entries = search.entries
            } catch {
                registerFailure(for: source.key)
                continue
            }

            // prefer an exact normalized title match, else the first result
            let match = entries.first { normalize($0.title) == normalizedQuery } ?? entries.first
            guard let match else { continue }

            guard let latest = await fetchLatestChapter(source: source, manga: match) else {
                continue
            }

            state.matches[uniqueKey] = MatchRef(
                sourceKey: source.key,
                mangaKey: match.key,
                sourceName: source.name
            )
            clearFailure(for: source.key)

            result.matchedSourceKey = source.key
            result.matchedMangaKey = match.key
            result.matchedSourceName = source.name
            result.latestChapter = latest
            result.currentChapter = currentChapter
            return result
        }

        // no match found anywhere; still record the (negative) result so we cache it
        result.currentChapter = currentChapter
        return result
    }

    /// Highest chapter number available on a source for a given manga.
    private func fetchLatestChapter(source: AidokuRunner.Source, manga: AidokuRunner.Manga) async -> Float? {
        if isSourceSkipped(source.key) { return nil }
        await throttle()
        do {
            let updated = try await SourceRequestContext.$nonInteractive.withValue(true) {
                try await source.getMangaUpdate(manga: manga, needsDetails: false, needsChapters: true)
            }
            clearFailure(for: source.key)
            return metric(updated.chapters ?? [])
        } catch {
            registerFailure(for: source.key)
            return nil
        }
    }

    // MARK: - Helpers

    private func candidateSources(excluding currentSourceKey: String) -> [AidokuRunner.Source] {
        let excluded = excludedSources
        return SourceManager.shared.sources.filter { source in
            source.key != currentSourceKey
                && source.key != LocalSourceRunner.sourceKey
                && !excluded.contains(source.key)
                && !isSourceSkipped(source.key)
        }
    }

    private func localLatestChapter(sourceKey: String, mangaKey: String) async -> Float? {
        await CoreDataManager.shared.container.performBackgroundTask { context in
            let objects = CoreDataManager.shared.getChapters(
                sourceId: sourceKey,
                mangaId: mangaKey,
                context: context
            )
            let chapters = objects.map { $0.toChapter() }
            let nums = chapters.compactMap { $0.chapterNum }
            if let max = nums.max() {
                return max
            }
            return chapters.isEmpty ? nil : Float(chapters.count)
        }
    }

    private func metric(_ chapters: [AidokuRunner.Chapter]) -> Float? {
        let nums = chapters.compactMap { $0.chapterNumber }
        if let max = nums.max() {
            return max
        }
        return chapters.isEmpty ? nil : Float(chapters.count)
    }

    private func normalize(_ string: String) -> String {
        string
            .lowercased()
            .folding(options: .diacriticInsensitive, locale: nil)
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    private func throttle() async {
        try? await Task.sleep(nanoseconds: UInt64.random(in: 200_000_000...500_000_000))
    }

    private func isExpired(_ result: CrossSourceResult) -> Bool {
        Date().timeIntervalSince(result.checkedAt) > ttl
    }

    // MARK: - Source backoff

    private func isSourceSkipped(_ sourceKey: String) -> Bool {
        guard let entry = state.backoff[sourceKey] else { return false }
        return entry.until > Date()
    }

    private func registerFailure(for sourceKey: String) {
        var entry = state.backoff[sourceKey] ?? Backoff(until: Date(), failures: 0)
        entry.failures += 1
        // exponential backoff capped at 24h: 30m, 1h, 2h, ... 
        let minutes = min(30 * (1 << min(entry.failures - 1, 6)), 24 * 60)
        entry.until = Date().addingTimeInterval(TimeInterval(minutes * 60))
        state.backoff[sourceKey] = entry
    }

    private func clearFailure(for sourceKey: String) {
        state.backoff[sourceKey] = nil
    }

    // MARK: - Notifications

    @MainActor
    private func postResult(_ result: CrossSourceResult) {
        NotificationCenter.default.post(name: .crossSourceCheckCompleted, object: result)
    }

    @MainActor
    private func postCompleted() {
        NotificationCenter.default.post(name: .crossSourceCheckCompleted, object: nil)
    }

    // MARK: - Persistence

    private func loadFromDisk() {
        guard
            let data = try? Data(contentsOf: Self.cacheFileURL),
            let decoded = try? JSONDecoder().decode(PersistedState.self, from: data)
        else { return }
        // drop expired results on load
        state = decoded
        state.results = state.results.filter { !isExpired($0.value) }
    }

    private func persist() {
        let snapshot = PersistedState(
            results: state.results.filter { !isExpired($0.value) },
            matches: state.matches,
            backoff: state.backoff.filter { $0.value.until > Date() }
        )
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        try? data.write(to: Self.cacheFileURL, options: .atomic)
    }
}
