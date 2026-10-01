import Foundation
import UniformTypeIdentifiers

// Orchestrates one AutoFrameIO watch session: a serial queue that, for each
// stable file the watcher reports, uploads an image as-is or encodes a video
// first, mirrors the watch folder's subfolder structure into Frame.io, and
// creates one share + sends one notification email the first time a file
// lands in a new containing folder. Later files in that same folder upload
// silently — the Frame.io folder share auto-updates.
//
// Almost every watch root mirrors exactly as found: whatever sits directly
// inside the chosen watch path becomes the share unit, and everything
// nested inside it — however deep — mirrors into Frame.io as-is (see
// `mirrorRelativePath`).
//
// The one named exception is a watch root literally called "approvalExports"
// (`skipsFirstSegment`), which has an extra organizational layer above the
// dated delivery folder: a "stills" and/or "quicktimes" folder full of dated
// folders (stills/2026_09_25_1438, quicktimes/2026_09_25_1437, ...). For
// that specific layout only, the first segment is skipped — it's never
// replicated into Frame.io, the local encode output, or a share name — so
// the dated folder (not "stills"/"quicktimes") is what actually mirrors and
// is the share/email batch key.
//
// Either way, a file with no folder above it at the relevant level (sitting
// directly in the watch root, or — for approvalExports — directly inside
// "stills"/"quicktimes" with no dated folder of its own) mirrors to the
// project root and never triggers a share.
//
// Ported from autoframeio/autoframeio/session.py (the standalone Python
// tool at /Users/ian.fallon/Documents/Claude/autoframeio). Reuses Transcoda's
// own already-authenticated FrameIOAPIClient/FrameIOAuthManager rather than
// the separate OAuth app + local HTTPS callback server that standalone tool
// needed.
//
// FrameIOAPIClient is completion-closure based; this wraps each call with a
// semaphore so processing stays strictly one file at a time on `workQueue`
// without deeply nesting callbacks — matching the Python version's own
// single-worker-thread queue. Never call anything here from the main thread.
final class AutoFrameIOSession {
    struct Config {
        let watchRoot: URL
        let accountID: String
        let projectID: String
        let rootFolderID: String
        let projectName: String
        let notifyAddresses: [String]
    }

    enum Event {
        case uploaded(filename: String, destination: String)
        case shared(folderName: String, url: String)
        case shareFailed(folderName: String, message: String)
        case emailSent(folderName: String, addresses: [String])
        case emailFailed(folderName: String, message: String)
        case failed(filename: String, message: String)
    }

    private let config: Config
    private let workQueue = DispatchQueue(label: "autoframeio.session", qos: .utility)

    // relative folder path (e.g. "2026-09-25/interviews") -> Frame.io folder id
    private var folderCache: [String: String] = [:]
    // relative containing-folder path -> true once its share/email has gone out
    private var sharedFolders: Set<String> = []

    // Called on an arbitrary background thread — hop to main yourself if
    // updating UI state directly instead of via SwiftUI @Published/@State.
    var onEvent: ((Event) -> Void)?

    init(config: Config) {
        self.config = config
    }

    func handle(fileURL: URL) {
        workQueue.async { [weak self] in
            self?.process(fileURL)
        }
    }

    // MARK: - Per-file processing

    private func process(_ source: URL) {
        let ext = source.pathExtension.lowercased()
        let isImage = AutoFrameIOConstants.imageExtensions.contains(ext)
        let isVideo = AutoFrameIOConstants.videoExtensions.contains(ext)
        guard isImage || isVideo else { return }

        // The first path segment under the watch root (e.g. "stills" /
        // "quicktimes") is treated as a purely local organizational folder —
        // it's never replicated into Frame.io, the local encode output, the
        // upload destination, or the share name. Only what's inside it (a
        // dated delivery folder, typically) actually mirrors. A file with no
        // second segment at all (sitting directly in the watch root, or
        // directly in "quicktimes" with no dated folder of its own) mirrors
        // to the project root and never triggers a share.
        let relativeDir = mirrorRelativePath(for: relativeDirectory(of: source))

        let uploadURL: URL
        if isImage {
            uploadURL = source
        } else {
            let outputDir = relativeDir.isEmpty
                ? AutoFrameIOConstants.outputRoot
                : AutoFrameIOConstants.outputRoot.appendingPathComponent(relativeDir)
            let outputURL = outputDir.appendingPathComponent(source.deletingPathExtension().lastPathComponent + ".mp4")
            do {
                try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
                try encode(source: source, destination: outputURL)
            } catch {
                onEvent?(.failed(filename: source.lastPathComponent, message: error.localizedDescription))
                return
            }
            uploadURL = outputURL
        }

        guard let folderID = resolveFolderChainSync(relativeDir: relativeDir) else {
            onEvent?(.failed(filename: source.lastPathComponent, message: "Could not resolve Frame.io folder"))
            return
        }

        guard uploadSync(uploadURL, to: folderID) else { return }

        onEvent?(.uploaded(
            filename: uploadURL.lastPathComponent,
            destination: relativeDir.isEmpty ? config.projectName : "\(config.projectName)/\(relativeDir)"
        ))

        // The share/email batch key is always the dated folder itself — the
        // FIRST segment of the (already category-stripped) relativeDir —
        // even when a file is nested further inside it, e.g. a subfolder
        // created within the dated folder after it was already shared.
        // Frame.io folder shares already auto-include anything added later
        // to the shared folder or its descendants, so a deeper subfolder
        // must never trigger its own separate share. A file that mirrors to
        // the project root (relativeDir empty) never shares at all.
        if let batchKey = relativeDir.split(separator: "/").first.map(String.init),
           !sharedFolders.contains(batchKey) {
            createShareAndNotify(batchKey: batchKey)
        }
    }

    private func relativeDirectory(of source: URL) -> String {
        let watchPath = config.watchRoot.standardizedFileURL.path
        let sourcePath = source.standardizedFileURL.path
        guard sourcePath.hasPrefix(watchPath) else { return "" }
        var relative = String(sourcePath.dropFirst(watchPath.count))
        if relative.hasPrefix("/") { relative.removeFirst() }
        let components = relative.split(separator: "/").dropLast()  // drop filename
        return components.joined(separator: "/")
    }

    // Named exception for the one watch layout that has an extra
    // organizational folder above the dated delivery folder — see the
    // class-level comment. Every other watch root mirrors as-is.
    private var skipsFirstSegment: Bool {
        config.watchRoot.lastPathComponent.caseInsensitiveCompare("approvalExports") == .orderedSame
    }

    private func mirrorRelativePath(for relativeDir: String) -> String {
        guard skipsFirstSegment else { return relativeDir }
        guard !relativeDir.isEmpty else { return "" }
        let segments = relativeDir.split(separator: "/")
        guard segments.count > 1 else { return "" }
        return segments.dropFirst().joined(separator: "/")
    }

    // MARK: - Encoding

    private func encode(source: URL, destination: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: ffmpegPath)
        process.arguments = AutoFrameIOConstants.ffmpegArguments(input: source.path, output: destination.path)
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0, FileManager.default.fileExists(atPath: destination.path) else {
            throw NSError(domain: "AutoFrameIO", code: Int(process.terminationStatus), userInfo: [
                NSLocalizedDescriptionKey: "ffmpeg failed encoding \(source.lastPathComponent) (exit code \(process.terminationStatus))"
            ])
        }
    }

    // MARK: - Frame.io folder mirroring (blocking wrappers)

    private func resolveFolderChainSync(relativeDir: String) -> String? {
        guard !relativeDir.isEmpty else { return config.rootFolderID }

        var parentID = config.rootFolderID
        var cumulative = ""
        for segment in relativeDir.split(separator: "/") {
            cumulative = cumulative.isEmpty ? String(segment) : "\(cumulative)/\(segment)"
            if let cachedID = folderCache[cumulative] {
                parentID = cachedID
                continue
            }
            let semaphore = DispatchSemaphore(value: 0)
            var newFolderID: String?
            FrameIOAPIClient.shared.createFolder(accountID: config.accountID, parentFolderID: parentID, name: String(segment)) { result in
                if case .success(let folder) = result { newFolderID = folder.id }
                semaphore.signal()
            }
            semaphore.wait()
            guard let folderID = newFolderID else { return nil }
            folderCache[cumulative] = folderID
            parentID = folderID
        }
        return parentID
    }

    private func uploadSync(_ fileURL: URL, to folderID: String) -> Bool {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
              let fileSize = (attrs[.size] as? NSNumber)?.int64Value else {
            onEvent?(.failed(filename: fileURL.lastPathComponent, message: "Couldn't read file size"))
            return false
        }

        let semaphore = DispatchSemaphore(value: 0)
        var success = false
        var failureMessage: String?

        FrameIOAPIClient.shared.createFileUpload(accountID: config.accountID, parentFolderID: folderID, name: fileURL.lastPathComponent, fileSize: fileSize) { result in
            switch result {
            case .failure(let error):
                failureMessage = error.localizedDescription
                semaphore.signal()
            case .success(let asset):
                guard let chunks = asset.uploadURLs, !chunks.isEmpty else {
                    failureMessage = "Frame.io didn't return an upload target for \(fileURL.lastPathComponent)"
                    semaphore.signal()
                    return
                }
                FrameIOAPIClient.shared.uploadChunks(chunks, fileURL: fileURL, contentType: Self.mimeType(for: fileURL), progress: { _ in }) { uploadResult in
                    switch uploadResult {
                    case .failure(let error): failureMessage = error.localizedDescription
                    case .success: success = true
                    }
                    semaphore.signal()
                }
            }
        }
        semaphore.wait()

        if !success {
            onEvent?(.failed(filename: fileURL.lastPathComponent, message: failureMessage ?? "Upload failed"))
        }
        return success
    }

    // MARK: - Share + notify

    private func createShareAndNotify(batchKey: String) {
        guard let folderID = folderCache[batchKey] else { return }

        let semaphore = DispatchSemaphore(value: 0)
        var share: FrameIOShare?
        var failureMessage: String?

        FrameIOAPIClient.shared.createShare(accountID: config.accountID, projectID: config.projectID, name: batchKey, assetIDs: [folderID]) { result in
            switch result {
            case .success(let created): share = created
            case .failure(let error): failureMessage = error.localizedDescription
            }
            semaphore.signal()
        }
        semaphore.wait()

        guard let share else {
            onEvent?(.shareFailed(folderName: batchKey, message: failureMessage ?? "Could not create share"))
            return
        }
        sharedFolders.insert(batchKey)
        onEvent?(.shared(folderName: batchKey, url: share.shortURL))

        let subject = "[Frame.io] New \(config.projectName) link available"
        let body = """
        New exports for \(config.projectName) have landed in "\(batchKey)" and been uploaded to Frame.io.

        Viewable link: \(share.shortURL)

        Any further files added to this folder will appear under the same link.
        """
        do {
            try SMTPMailer.send(to: config.notifyAddresses, subject: subject, body: body)
            onEvent?(.emailSent(folderName: batchKey, addresses: config.notifyAddresses))
        } catch {
            onEvent?(.emailFailed(folderName: batchKey, message: error.localizedDescription))
        }
    }

    private static func mimeType(for url: URL) -> String {
        if let type = UTType(filenameExtension: url.pathExtension) {
            return type.preferredMIMEType ?? "application/octet-stream"
        }
        return "application/octet-stream"
    }
}
