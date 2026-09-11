import Foundation
import Combine

enum JobStatus: Equatable {
    case waiting
    case encoding
    case complete
    case failed(String)
}

// Deliberately independent of JobStatus — an upload failure must never be
// mistaken for (or mask) a successful encode, and vice versa.
enum FrameIOUploadStatus: Equatable {
    case none
    case uploading(progress: Double)
    case uploaded
    case failed(String)
}

class EncodingJob: ObservableObject, Identifiable {
    let id = UUID()
    let inputURL: URL

    // Set when this job came from expanding a dropped/selected folder — the
    // relative path (starting with the top folder's own name) from that folder
    // down to this file, e.g. "sunshine" or "sunshine/interviews". nil for a
    // standalone file. Used to mirror the source folder structure under a
    // custom output directory — see EncodingJob.resolvedOutputURL.
    let sourceRelativeDirectory: String?

    @Published var status: JobStatus  = .waiting
    @Published var progress: Double   = 0.0
    @Published var elapsedSeconds: Double = 0
    @Published var fps: Double        = 0

    // Fetched once via ffprobe right after the job is queued (see EncodingQueue.add),
    // independent of preset/settings — used to estimate output file size before
    // encoding starts.
    @Published var sourceDurationSeconds: Double? = nil

    // Stamped at encode time — a frozen VALUE COPY of Preset, so later edits to
    // the working preset (or deletion of a saved custom preset) never affect a
    // job that has already been stamped/queued/run.
    var preset: Preset = BuiltInPresets.mp4
    var outputDirectory: URL?
    var customFileName: String = ""   // overrides stem entirely if set
    var customSuffix: String   = ""   // appended to original stem if set

    // Frame.io upload — stamped at encode time alongside the fields above.
    // frameIOBatchTimestamp names the shared destination folder for a
    // standalone file (see FrameIOUploadManager); frameIOBatchID groups every
    // job from the same Encode-press for upload-completion tracking, kept
    // separate from the human-readable timestamp since two batches started
    // within the same minute would otherwise collide.
    var frameIOUploadEnabled: Bool = false
    var frameIOAccountID: String?
    var frameIOProjectID: String?
    var frameIORootFolderID: String?
    var frameIOBatchTimestamp: String?
    var frameIOBatchID: UUID?
    @Published var uploadStatus: FrameIOUploadStatus = .none

    // Soundlay — stamped at encode time like the fields above, but never part
    // of Preset/StructuredSettings itself: a specific audio file is a
    // one-off per-session choice, not a reusable encode setting (unlike Mute/
    // Timecode Track, which are genuinely part of the preset).
    var soundlayAudioURL: URL?

    init(inputURL: URL, sourceRelativeDirectory: String? = nil) {
        self.inputURL = inputURL
        self.sourceRelativeDirectory = sourceRelativeDirectory
    }

    var outputURL: URL {
        EncodingJob.resolvedOutputURL(
            inputURL: inputURL,
            preset: preset,
            outputDirectory: outputDirectory,
            customFileName: customFileName,
            customSuffix: customSuffix,
            sourceRelativeDirectory: sourceRelativeDirectory
        )
    }

    // Shared with ContentView's pre-flight collision check, so it can preview
    // what a job's output path WOULD be under the currently-edited settings,
    // before those settings are actually stamped onto the job at encode time.
    //
    // sourceRelativeDirectory only applies when a custom outputDirectory is set —
    // "Same as source" (outputDirectory == nil) always writes alongside the
    // original file regardless of which folder it was found in.
    static func resolvedOutputURL(inputURL: URL, preset: Preset, outputDirectory: URL?, customFileName: String, customSuffix: String, sourceRelativeDirectory: String? = nil) -> URL {
        let dir: URL
        if let outputDirectory {
            if let sourceRelativeDirectory {
                dir = outputDirectory.appendingPathComponent(sourceRelativeDirectory, isDirectory: true)
            } else {
                dir = outputDirectory
            }
        } else {
            dir = inputURL.deletingLastPathComponent()
        }
        let ext  = preset.outputExtension

        let stem: String
        if !customFileName.isEmpty {
            // Use exact filename provided (strip extension if user included one)
            stem = URL(fileURLWithPath: customFileName).deletingPathExtension().lastPathComponent
        } else {
            let originalStem = inputURL.deletingPathExtension().lastPathComponent
            if !customSuffix.isEmpty {
                stem = originalStem + customSuffix
            } else {
                stem = originalStem + preset.outputSuffix
            }
        }

        return dir
            .appendingPathComponent(stem)
            .appendingPathExtension(ext)
    }

    var displayName: String { inputURL.lastPathComponent }

    var isTranscribeJob: Bool {
        if case .transcribe = preset.kind { return true }
        return false
    }

    var isVidCheckerJob: Bool {
        if case .vidchecker = preset.kind { return true }
        return false
    }

    // Set once VidChecker returns a task ID, used to poll GetTask.
    var vidCheckerTaskId: Int?

    // The raw CheckResult name ("Passed"/"Warning"/"Failed"/"Reject") once a
    // VidChecker job finishes — shown in place of the generic "Complete"/
    // "Failed: ..." label, since the check result itself IS the meaningful
    // outcome for this kind of job.
    @Published var vidCheckerCheckResult: String?

    var statusLabel: String {
        switch status {
        case .waiting:
            return "Waiting"
        case .encoding:
            return isVidCheckerJob ? "Checking…" : (isTranscribeJob ? "Transcribing…" : "Encoding…")
        case .complete:
            return isVidCheckerJob ? (vidCheckerCheckResult ?? "Complete") : "Complete"
        case .failed(let e):
            return isVidCheckerJob ? (vidCheckerCheckResult ?? "Failed") : "Failed: \(e)"
        }
    }
}
