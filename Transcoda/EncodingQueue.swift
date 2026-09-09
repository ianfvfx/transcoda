import Foundation
import Combine
import AppKit
import UserNotifications

class EncodingQueue: ObservableObject {
    @Published var jobs: [EncodingJob] = []
    @Published var isRunning = false

    private var currentProcess: Process?
    private let frameIOUploadManager = FrameIOUploadManager()

    static let videoExtensions: Set<String> = ["mp4", "mov", "mxf", "avi", "mkv", "m4v", "mpg", "mpeg", "mts", "m2ts"]

    // MARK: - Public API

    // Accepts a mix of file and folder URLs — folders are recursively scanned
    // for video files, and each one found is tagged with its path relative to
    // the top folder (see EncodingJob.sourceRelativeDirectory) so a custom
    // output directory can mirror the source folder structure.
    func add(urls: [URL]) {
        let newJobs = urls.flatMap { url -> [EncodingJob] in
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return [] }
            if isDirectory.boolValue {
                return jobsForFolder(url)
            } else if EncodingQueue.videoExtensions.contains(url.pathExtension.lowercased()) {
                return [EncodingJob(inputURL: url)]
            } else {
                return []
            }
        }
        jobs.append(contentsOf: newJobs)

        // Duration is a property of the source file, not of the chosen preset, so
        // fetch it once here rather than re-probing every time settings change.
        for job in newJobs {
            DispatchQueue.global(qos: .utility).async {
                let duration = PresetConfig.duration(job.inputURL)
                DispatchQueue.main.async {
                    job.sourceDurationSeconds = duration > 0 ? duration : nil
                }
            }
        }
    }

    private func jobsForFolder(_ folderURL: URL) -> [EncodingJob] {
        let topFolderName = folderURL.lastPathComponent
        let folderComponents = folderURL.standardizedFileURL.pathComponents

        guard let enumerator = FileManager.default.enumerator(
            at: folderURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return [] }

        var result: [EncodingJob] = []
        for case let fileURL as URL in enumerator {
            let isDir = (try? fileURL.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            guard !isDir, EncodingQueue.videoExtensions.contains(fileURL.pathExtension.lowercased()) else { continue }

            let containingDirComponents = fileURL.deletingLastPathComponent().standardizedFileURL.pathComponents
            let extraComponents = containingDirComponents.count > folderComponents.count
                ? Array(containingDirComponents.suffix(from: folderComponents.count))
                : []
            let relativeDirectory = ([topFolderName] + extraComponents).joined(separator: "/")

            result.append(EncodingJob(inputURL: fileURL, sourceRelativeDirectory: relativeDirectory))
        }
        return result
    }

    func start(preset: Preset,
               outputDirectory: URL?,
               outputFileName: String,
               outputSuffix: String,
               frameIOProject: FrameIOProjectOption? = nil) {
        guard !isRunning else { return }

        let batchID = UUID()
        let batchTimestamp = Self.makeBatchTimestamp()

        for job in jobs where job.status == .waiting {
            // Substitutes a per-file calculated bitrate when Max File Size is
            // active, using this job's own duration — a no-op otherwise.
            job.preset          = PresetConfig.effectivePreset(for: preset, sourceDurationSeconds: job.sourceDurationSeconds)
            job.outputDirectory = outputDirectory
            job.customFileName  = outputFileName
            job.customSuffix    = outputSuffix

            job.frameIOUploadEnabled = frameIOProject != nil
            job.frameIOAccountID     = frameIOProject?.accountID
            job.frameIOProjectID     = frameIOProject?.project.id
            job.frameIORootFolderID  = frameIOProject?.project.rootFolderID
            job.frameIOBatchTimestamp = batchTimestamp
            job.frameIOBatchID        = batchID
        }

        if let frameIOProject {
            let uploadingJobs = jobs.filter { $0.status == .waiting && $0.frameIOUploadEnabled }
            frameIOUploadManager.startBatch(
                jobs: uploadingJobs,
                accountID: frameIOProject.accountID,
                projectID: frameIOProject.project.id,
                rootFolderID: frameIOProject.project.rootFolderID,
                batchID: batchID
            )
        }

        isRunning = true
        encodeNext()
    }

    // Format matches the "YYYY_MM_DD_HHMM" folder-naming spec for standalone
    // (non-folder-dropped) files uploaded to Frame.io.
    private static func makeBatchTimestamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy_MM_dd_HHmm"
        return formatter.string(from: Date())
    }

    func cancel() {
        currentProcess?.terminate()
        isRunning = false
    }

    func removeCompleted() {
        jobs.removeAll {
            if case .complete = $0.status { return true }
            return false
        }
    }

    // Not allowed for the job currently mid-encode — its ffmpeg process is
    // already running, and removing it here would just orphan that process
    // without any way to track or cancel it via the UI.
    func remove(_ job: EncodingJob) {
        guard job.status != .encoding else { return }
        jobs.removeAll { $0.id == job.id }
    }

    func clear() {
        guard !isRunning else { return }
        jobs.removeAll()
    }

    // MARK: - Private encoding loop

    private func encodeNext() {
        guard let job = jobs.first(where: { $0.status == .waiting }) else {
            isRunning = false
            notifyComplete()
            return
        }
        encode(job: job) { [weak self] in
            self?.encodeNext()
        }
    }

    private func encode(job: EncodingJob, completion: @escaping () -> Void) {
        if case .transcribe = job.preset.kind {
            encodeTranscribe(job: job, completion: completion)
            return
        }

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }

            let sourceDuration = PresetConfig.duration(job.inputURL)
            let duration = PresetConfig.effectiveDuration(for: job.preset, sourceDuration: sourceDuration)
            DispatchQueue.main.async { job.status = .encoding }

            // Output may land in a not-yet-existing subfolder (e.g. mirroring a
            // dropped folder's structure under a custom output directory) — ffmpeg
            // won't create intermediate directories itself.
            try? FileManager.default.createDirectory(
                at: job.outputURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )

            let process = Process()
            process.executableURL = URL(fileURLWithPath: ffmpegPath)
            process.arguments     = PresetConfig.arguments(
                preset: job.preset,
                inputURL: job.inputURL,
                input: job.inputURL.path,
                output: job.outputURL.path
            )

            let pipe = Pipe()
            process.standardOutput = pipe
            let readStderr = EncodingQueue.attachStderrCapture(to: process)
            self.currentProcess = process

            let startTime = Date()
            pipe.fileHandleForReading.readabilityHandler = { handle in
                let text = String(data: handle.availableData, encoding: .utf8) ?? ""
                self.parseProgress(text: text, job: job, duration: duration, startTime: startTime)
            }

            do {
                try process.run()
            } catch {
                DispatchQueue.main.async {
                    job.status = .failed(error.localizedDescription)
                    if job.frameIOUploadEnabled { self.frameIOUploadManager.skipDueToEncodeFailure(job) }
                }
                completion()
                return
            }

            process.waitUntilExit()
            pipe.fileHandleForReading.readabilityHandler = nil
            let capturedStderr = readStderr()

            DispatchQueue.main.async {
                if process.terminationStatus == 0 {
                    job.status   = .complete
                    job.progress = 1.0
                    if job.frameIOUploadEnabled { self.frameIOUploadManager.enqueue(job) }
                } else {
                    let tail = EncodingQueue.lastLines(capturedStderr, count: 3)
                    job.status = .failed(tail.isEmpty ? "Exit code \(process.terminationStatus)" : tail)
                    if job.frameIOUploadEnabled { self.frameIOUploadManager.skipDueToEncodeFailure(job) }
                }
                completion()
            }
        }
    }

    // No ffmpeg involved at all — runs the bundled transcribeSRTs.py against
    // the external Whisper Python environment to produce an .srt from the
    // source file's audio. No stdout progress channel like ffmpeg's
    // -progress pipe:1, so progress just stays indeterminate until it
    // finishes (JobRowView shows a spinner rather than a percentage for it).
    private func encodeTranscribe(job: EncodingJob, completion: @escaping () -> Void) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }

            DispatchQueue.main.async { job.status = .encoding }

            try? FileManager.default.createDirectory(
                at: job.outputURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )

            let args = PresetConfig.transcribeArguments(input: job.inputURL.path, output: job.outputURL.path)
            guard !args.isEmpty else {
                DispatchQueue.main.async {
                    job.status = .failed("transcribeSRTs.py not found in app bundle.")
                }
                completion()
                return
            }

            let process = Process()
            process.executableURL = URL(fileURLWithPath: transcribePythonPath)
            process.arguments     = args
            let readStderr = EncodingQueue.attachStderrCapture(to: process)
            self.currentProcess = process

            do {
                try process.run()
            } catch {
                // Most likely cause: the whisper-env venv hasn't been set up
                // yet on this machine — see setup_transcoda_whisper.command.
                DispatchQueue.main.async {
                    job.status = .failed("Couldn't launch transcription environment — has setup_transcoda_whisper.command been run on this Mac? (\(error.localizedDescription))")
                }
                completion()
                return
            }

            process.waitUntilExit()
            let capturedStderr = readStderr()

            DispatchQueue.main.async {
                if process.terminationStatus == 0 {
                    job.status   = .complete
                    job.progress = 1.0
                    if job.frameIOUploadEnabled { self.frameIOUploadManager.enqueue(job) }
                } else {
                    let tail = EncodingQueue.lastLines(capturedStderr, count: 3)
                    job.status = .failed(tail.isEmpty ? "Exit code \(process.terminationStatus)" : tail)
                }
                completion()
            }
        }
    }

    // Wires up continuous stderr capture on `process` (so it never blocks
    // trying to write to a full, undrained pipe buffer) and returns a closure
    // to retrieve what's been captured — call after waitUntilExit().
    private static func attachStderrCapture(to process: Process) -> () -> String {
        let stderrPipe = Pipe()
        process.standardError = stderrPipe
        let queue = DispatchQueue(label: "com.transcoda.stderr-capture")
        var output = ""
        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            queue.sync { output += text }
        }
        return {
            stderrPipe.fileHandleForReading.readabilityHandler = nil
            return queue.sync { output }
        }
    }

    // Verbose subprocess stderr (banner/info/warnings) usually has the actual
    // fatal error among the last few lines before exiting — that's what's
    // worth showing in a compact queue row.
    private static func lastLines(_ text: String, count: Int) -> String {
        let lines = text
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        return lines.suffix(count).joined(separator: " — ")
    }

    // MARK: - Progress parsing

    private func parseProgress(text: String, job: EncodingJob, duration: Double, startTime: Date) {
        let lines = text.components(separatedBy: "\n")
        var kv: [String: String] = [:]
        for line in lines {
            let parts = line.split(separator: "=", maxSplits: 1)
            if parts.count == 2 { kv[String(parts[0])] = String(parts[1]) }
        }
        if let timeStr = kv["out_time_us"], let timeUS = Double(timeStr), duration > 0 {
            let progress = min(timeUS / 1_000_000 / duration, 1.0)
            let fps      = Double(kv["fps"] ?? "0") ?? 0
            let elapsed  = Date().timeIntervalSince(startTime)
            DispatchQueue.main.async {
                job.progress       = progress
                job.fps            = fps
                job.elapsedSeconds = elapsed
            }
        }
    }

    // MARK: - Completion notification

    private func notifyComplete() {
        let total   = jobs.count
        let failed  = jobs.filter { if case .failed = $0.status { return true }; return false }.count
        let success = total - failed

        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }
            let content   = UNMutableNotificationContent()
            content.title = "Queue Complete"
            content.body  = "\(success) of \(total) file\(total == 1 ? "" : "s") processed successfully."
            content.sound = .default
            let request   = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
            center.add(request)
        }
    }
}
