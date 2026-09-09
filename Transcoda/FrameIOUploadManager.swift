import AppKit
import Foundation
import UniformTypeIdentifiers
import UserNotifications

// Owned by EncodingQueue — its lifecycle is entirely batch-driven (one batch
// per Encode-press that has Frame.io upload enabled). Uploads run strictly
// one at a time via an internal FIFO, deliberately mirroring
// EncodingQueue.encodeNext()'s self-recursive-completion style; this keeps
// per-batch folder creation trivially race-free (no two jobs ever resolve a
// destination folder concurrently) without needing extra coalescing logic.
final class FrameIOUploadManager {
    private struct Batch {
        var pendingJobIDs: Set<UUID>
        var folderCache: [String: String] = [:]   // relative path (or timestamp) -> Frame.io folder ID
        var topLevelFolders: [String: String] = [:]   // Frame.io folder ID -> folder name, for the share's asset list and name
        var anyFailed = false
        let accountID: String
        let projectID: String
        let rootFolderID: String
    }

    private var batches: [UUID: Batch] = [:]       // keyed by an internal batch ID, NOT the human-readable timestamp (which could collide across two back-to-back Encode presses within the same minute)
    private var jobToBatchKey: [UUID: UUID] = [:]
    private var uploadFIFO: [EncodingJob] = []
    private var isUploading = false

    // Called once per Encode-press (only when at least one job has Frame.io
    // upload enabled), registering the FULL pending set up front so a batch
    // can never be mistaken as "done" after just its first job completes.
    func startBatch(jobs: [EncodingJob], accountID: String, projectID: String, rootFolderID: String, batchID: UUID) {
        guard !jobs.isEmpty else { return }
        batches[batchID] = Batch(
            pendingJobIDs: Set(jobs.map { $0.id }),
            accountID: accountID,
            projectID: projectID,
            rootFolderID: rootFolderID
        )
        for job in jobs {
            jobToBatchKey[job.id] = batchID
        }
    }

    // Called when a Frame.io-enabled job's encode finishes successfully.
    func enqueue(_ job: EncodingJob) {
        uploadFIFO.append(job)
        drainIfIdle()
    }

    // Called when a Frame.io-enabled job's ENCODE fails (never reaches the
    // upload stage at all). Without this, that job's ID would sit in
    // pendingJobIDs forever — enqueue()/settle() only ever run for jobs whose
    // encode actually succeeded — and the batch would never finish, so no
    // review link would ever be created even if every other file uploaded
    // fine. Counts as a batch failure, same as an upload failure would.
    func skipDueToEncodeFailure(_ job: EncodingJob) {
        guard let batchID = jobToBatchKey[job.id] else { return }
        batches[batchID]?.anyFailed = true
        settle(jobID: job.id, batchID: batchID)
    }

    // MARK: - FIFO draining

    private func drainIfIdle() {
        guard !isUploading, !uploadFIFO.isEmpty else { return }
        isUploading = true
        let job = uploadFIFO.removeFirst()
        performUpload(job: job) { [weak self] in
            self?.isUploading = false
            self?.drainIfIdle()
        }
    }

    private func performUpload(job: EncodingJob, completion: @escaping () -> Void) {
        guard let batchID = jobToBatchKey[job.id] else { completion(); return }

        DispatchQueue.main.async { job.uploadStatus = .uploading(progress: 0) }

        resolveDestinationFolder(job: job, batchID: batchID) { [weak self] result in
            guard let self else { completion(); return }
            switch result {
            case .failure(let error):
                self.fail(job: job, batchID: batchID, message: error.localizedDescription, completion: completion)
            case .success(let folderID):
                self.recordTopLevelFolder(job: job, batchID: batchID)
                self.uploadFile(job: job, folderID: folderID, batchID: batchID, completion: completion)
            }
        }
    }

    // MARK: - Destination folder resolution

    // Dropped-folder jobs mirror their sourceRelativeDirectory as nested
    // folders under the project root; standalone files land in one folder
    // named after the batch's timestamp. Each path segment's folder is
    // created once and cached — a later job reusing "sunshine" as a parent
    // just reads the cache.
    private func resolveDestinationFolder(job: EncodingJob, batchID: UUID, completion: @escaping (Result<String, Error>) -> Void) {
        guard let batch = batches[batchID] else {
            completion(.failure(FrameIOError.notAuthenticated))
            return
        }
        let segments: [String]
        if let rel = job.sourceRelativeDirectory {
            segments = rel.split(separator: "/").map(String.init)
        } else {
            segments = [job.frameIOBatchTimestamp ?? "Transcoda Upload"]
        }
        guard !segments.isEmpty else {
            completion(.failure(FrameIOError.httpError(-1, "No destination folder for \(job.displayName)")))
            return
        }
        createFolderChain(segments: segments, index: 0, parentFolderID: batch.rootFolderID, cumulativePath: "", batchID: batchID, completion: completion)
    }

    private func createFolderChain(segments: [String], index: Int, parentFolderID: String, cumulativePath: String, batchID: UUID, completion: @escaping (Result<String, Error>) -> Void) {
        guard index < segments.count else {
            completion(.success(parentFolderID))
            return
        }
        let segment = segments[index]
        let path = cumulativePath.isEmpty ? segment : "\(cumulativePath)/\(segment)"

        if let cachedID = batches[batchID]?.folderCache[path] {
            createFolderChain(segments: segments, index: index + 1, parentFolderID: cachedID, cumulativePath: path, batchID: batchID, completion: completion)
            return
        }
        guard let batch = batches[batchID] else {
            completion(.failure(FrameIOError.notAuthenticated))
            return
        }
        FrameIOAPIClient.shared.createFolder(accountID: batch.accountID, parentFolderID: parentFolderID, name: segment) { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(let error):
                completion(.failure(error))
            case .success(let folder):
                self.batches[batchID]?.folderCache[path] = folder.id
                self.createFolderChain(segments: segments, index: index + 1, parentFolderID: folder.id, cumulativePath: path, batchID: batchID, completion: completion)
            }
        }
    }

    private func recordTopLevelFolder(job: EncodingJob, batchID: UUID) {
        let topKey: String
        if let rel = job.sourceRelativeDirectory, let first = rel.split(separator: "/").first {
            topKey = String(first)
        } else {
            topKey = job.frameIOBatchTimestamp ?? "Transcoda Upload"
        }
        if let topID = batches[batchID]?.folderCache[topKey] {
            // topKey IS the folder's name — it's the literal string passed to
            // createFolder for that segment, so no extra lookup is needed.
            batches[batchID]?.topLevelFolders[topID] = topKey
        }
    }

    // MARK: - File upload

    private func uploadFile(job: EncodingJob, folderID: String, batchID: UUID, completion: @escaping () -> Void) {
        guard let batch = batches[batchID] else { completion(); return }
        let fileURL = job.outputURL

        guard let attrs = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
              let fileSize = (attrs[.size] as? NSNumber)?.int64Value else {
            fail(job: job, batchID: batchID, message: "Couldn't read file size for \(fileURL.lastPathComponent)", completion: completion)
            return
        }

        FrameIOAPIClient.shared.createFileUpload(accountID: batch.accountID, parentFolderID: folderID, name: fileURL.lastPathComponent, fileSize: fileSize) { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(let error):
                self.fail(job: job, batchID: batchID, message: error.localizedDescription, completion: completion)
            case .success(let asset):
                guard let chunks = asset.uploadURLs, !chunks.isEmpty else {
                    self.fail(job: job, batchID: batchID, message: "Frame.io didn't return an upload target for \(fileURL.lastPathComponent)", completion: completion)
                    return
                }
                let contentType = Self.mimeType(for: fileURL)
                FrameIOAPIClient.shared.uploadChunks(chunks, fileURL: fileURL, contentType: contentType, progress: { fraction in
                    job.uploadStatus = .uploading(progress: fraction)
                }, completion: { uploadResult in
                    switch uploadResult {
                    case .failure(let error):
                        self.fail(job: job, batchID: batchID, message: error.localizedDescription, completion: completion)
                    case .success:
                        DispatchQueue.main.async { job.uploadStatus = .uploaded }
                        self.settle(jobID: job.id, batchID: batchID)
                        completion()
                    }
                })
            }
        }
    }

    private func fail(job: EncodingJob, batchID: UUID, message: String, completion: @escaping () -> Void) {
        DispatchQueue.main.async { job.uploadStatus = .failed(message) }
        batches[batchID]?.anyFailed = true
        settle(jobID: job.id, batchID: batchID)
        completion()
    }

    // MARK: - Batch completion

    private func settle(jobID: UUID, batchID: UUID) {
        batches[batchID]?.pendingJobIDs.remove(jobID)
        jobToBatchKey[jobID] = nil
        if let batch = batches[batchID], batch.pendingJobIDs.isEmpty {
            finishBatch(batchID)
        }
    }

    // Only creates a review link if every upload in the batch succeeded —
    // a partial batch is deliberately never shared, per spec. Named after the
    // uploaded folder(s) themselves rather than a generic label.
    private func finishBatch(_ batchID: UUID) {
        guard let batch = batches[batchID] else { return }
        batches[batchID] = nil
        guard !batch.anyFailed, !batch.topLevelFolders.isEmpty else { return }

        let shareName = batch.topLevelFolders.values.sorted().joined(separator: ", ")

        FrameIOAPIClient.shared.createShare(
            accountID: batch.accountID,
            projectID: batch.projectID,
            name: shareName,
            assetIDs: Array(batch.topLevelFolders.keys)
        ) { result in
            DispatchQueue.main.async {
                switch result {
                case .success(let share):
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(share.shortURL, forType: .string)
                    Self.notifyReviewLinkReady(share.shortURL)
                case .failure(let error):
                    Self.notifyReviewLinkFailed(error.localizedDescription)
                }
            }
        }
    }

    // MARK: - Notification

    // Modeled directly on EncodingQueue.notifyComplete() — a separate
    // notification, distinct from the "Queue Complete" one, since uploads
    // can finish well after the encode queue itself has drained.
    private static func notifyReviewLinkReady(_ shortURL: String) {
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = "Frame.io Upload Complete"
            content.body = "Review link copied to clipboard: \(shortURL)"
            content.sound = .default
            let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
            center.add(request)
        }
    }

    // Every file uploaded fine but creating the review link itself failed —
    // surface it rather than silently doing nothing, since that's otherwise
    // indistinguishable from success to anyone watching the queue.
    private static func notifyReviewLinkFailed(_ message: String) {
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = "Frame.io Review Link Failed"
            content.body = "All files uploaded, but creating the review link failed: \(message)"
            content.sound = .default
            let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
            center.add(request)
        }
    }

    private static func mimeType(for url: URL) -> String {
        if let type = UTType(filenameExtension: url.pathExtension) {
            return type.preferredMIMEType ?? "application/octet-stream"
        }
        return "application/octet-stream"
    }
}
