import Foundation

// Polling-based recursive folder watcher for the AutoFrameIO utility.
// Ported from autoframeio/autoframeio/watcher.py (the standalone Python
// tool at /Users/ian.fallon/Documents/Claude/autoframeio) — see that file's
// header comment for why polling is used instead of a native watch
// mechanism (FSEvents is unreliable over the network-mounted watch folders
// this is meant for).
//
// Only reports files created after `start()` — anything already present in
// the watch root is pre-seeded and never reported. A file whose size/mtime
// changes after being reported (e.g. the same filename re-rendered and
// overwritten) is treated as new and reported again.
final class AutoFrameIOWatcher {
    private struct FileStat: Equatable {
        let size: Int64
        let modified: Date
    }

    private let watchRoot: URL
    private let onDetected: (URL) -> Void
    private let onStableFile: (URL) -> Void

    // Serial — owns all mutable state below (lastKnownStats/inFlight/timer),
    // and runs the poll itself.
    private let queue = DispatchQueue(label: "autoframeio.watcher")
    // Concurrent — actually runs each file's stability wait (up to ~30s of
    // sleeping), so several files landing in the same poll cycle stabilise
    // in parallel instead of blocking the poll timer / each other in turn.
    private let stabilityQueue = DispatchQueue(label: "autoframeio.watcher.stability", attributes: .concurrent)
    private var timer: DispatchSourceTimer?
    private var lastKnownStats: [String: FileStat] = [:]
    private var inFlight: Set<String> = []
    private var isRunning = false

    init(watchRoot: URL, onDetected: @escaping (URL) -> Void, onStableFile: @escaping (URL) -> Void) {
        self.watchRoot = watchRoot
        self.onDetected = onDetected
        self.onStableFile = onStableFile
    }

    func start() {
        queue.async { [weak self] in
            guard let self else { return }
            self.isRunning = true
            // Pre-seed with anything already present so startup doesn't
            // re-process it — only new arrivals are ever reported.
            self.lastKnownStats = self.currentSnapshot()

            let timer = DispatchSource.makeTimerSource(queue: self.queue)
            timer.schedule(
                deadline: .now() + AutoFrameIOConstants.pollIntervalSeconds,
                repeating: AutoFrameIOConstants.pollIntervalSeconds
            )
            timer.setEventHandler { [weak self] in self?.poll() }
            timer.resume()
            self.timer = timer
        }
    }

    func stop() {
        queue.async { [weak self] in
            self?.isRunning = false
            self?.timer?.cancel()
            self?.timer = nil
        }
    }

    // MARK: - Polling

    private func currentSnapshot() -> [String: FileStat] {
        var result: [String: FileStat] = [:]
        guard let enumerator = FileManager.default.enumerator(
            at: watchRoot,
            includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey, .isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return result }

        for case let url as URL in enumerator {
            guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey, .isDirectoryKey]),
                  values.isDirectory != true else { continue }
            let size = Int64(values.fileSize ?? 0)
            let modified = values.contentModificationDate ?? Date.distantPast
            result[url.standardizedFileURL.path] = FileStat(size: size, modified: modified)
        }
        return result
    }

    private func poll() {
        guard isRunning else { return }
        let snapshot = currentSnapshot()

        for (path, stat) in snapshot {
            guard !inFlight.contains(path) else { continue }
            if let known = lastKnownStats[path], known == stat {
                continue
            }
            inFlight.insert(path)
            let url = URL(fileURLWithPath: path)
            onDetected(url)
            stabilityQueue.asyncAfter(deadline: .now() + AutoFrameIOConstants.ingestDelaySeconds) { [weak self] in
                self?.waitForStabilityThenHandle(url: url)
            }
        }

        // Drop stats for files that vanished, so a same-named file that
        // reappears later (a re-render mid-copy) is treated as new rather
        // than "unchanged since last poll."
        for path in lastKnownStats.keys where snapshot[path] == nil {
            lastKnownStats.removeValue(forKey: path)
        }
    }

    // Runs on `stabilityQueue` (concurrent) via the asyncAfter above, so
    // several files stability-checking at once don't block each other or
    // the poll timer on `queue`. Only touches `lastKnownStats`/`inFlight`
    // via `queue.async`, never directly.
    private func waitForStabilityThenHandle(url: URL) {
        var lastSize: Int64 = -1
        var stableCount = 0

        for _ in 0..<AutoFrameIOConstants.stabilityChecks {
            guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize else {
                finishInFlight(path: url.standardizedFileURL.path)
                return
            }
            let size64 = Int64(size)
            if size64 == lastSize && size64 > 0 {
                stableCount += 1
                if stableCount >= 2 { break }
            } else {
                stableCount = 0
            }
            lastSize = size64
            Thread.sleep(forTimeInterval: AutoFrameIOConstants.stabilityIntervalSeconds)
        }

        guard FileManager.default.fileExists(atPath: url.path) else {
            finishInFlight(path: url.standardizedFileURL.path)
            return
        }

        // Record the settled stat before handing off, so an unrelated poll
        // firing while this file is being processed doesn't re-report it.
        if let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]) {
            let size = Int64(values.fileSize ?? 0)
            let modified = values.contentModificationDate ?? Date.distantPast
            let path = url.standardizedFileURL.path
            queue.async { [weak self] in
                self?.lastKnownStats[path] = FileStat(size: size, modified: modified)
            }
        }

        onStableFile(url)
        finishInFlight(path: url.standardizedFileURL.path)
    }

    private func finishInFlight(path: String) {
        queue.async { [weak self] in
            self?.inFlight.remove(path)
        }
    }
}
