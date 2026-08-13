import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @StateObject private var queue         = EncodingQueue()
    @StateObject private var presetStore   = PresetStore.shared
    @EnvironmentObject private var launchURLs: LaunchURLs

    // The in-session, editable working copy. Selecting a preset (including
    // reselecting the current one) always reloads a fresh canonical copy from
    // presetStore, discarding any unsaved edits — see EncodeOptionsView.
    @State private var workingPreset: Preset   = BuiltInPresets.mp4
    @State private var useCustomOutput: Bool   = false
    @State private var outputDirectory: URL?   = nil
    @State private var outputFileName: String  = ""
    @State private var outputSuffix: String    = ""
    @State private var isDropTargeted: Bool     = false

    private var canStart: Bool {
        !queue.isRunning &&
        !queue.jobs.isEmpty &&
        queue.jobs.contains(where: { $0.status == .waiting }) &&
        optionsValid &&
        collidingJobs.isEmpty &&
        pendingDurationJobs.isEmpty
    }

    private var optionsValid: Bool {
        if case .structured(let settings) = workingPreset.kind, settings.codecFamily == .h264Mp4 {
            let maxSize = settings.maxFileSizeMB.trimmingCharacters(in: .whitespaces)
            if !maxSize.isEmpty {
                // Max File Size active — it supersedes bitrateMbps entirely, so
                // only maxFileSizeMB itself needs to be a valid positive number.
                guard let v = Double(maxSize), v > 0 else { return false }
            } else {
                // Blank bitrate is fine — PresetConfig falls back to the default.
                // Anything entered must still be a valid positive number, though
                // (Double, not Int — fractional Mbps like 12.5 is valid ffmpeg
                // input and already flows through the actual encode/estimate
                // paths unchanged; this was the only place still Int-only).
                let trimmed = settings.bitrateMbps.trimmingCharacters(in: .whitespaces)
                if !trimmed.isEmpty {
                    guard let v = Double(trimmed), v > 0 else { return false }
                }
            }
        }
        if customResolutionInvalid { return false }
        if useCustomOutput && outputDirectory == nil { return false }
        return true
    }

    // Custom Width/Height (shared by both codec families) must both be valid
    // positive EVEN integers — yuv420p chroma subsampling halves each
    // dimension, so an odd value fails the encode outright. Only checked when
    // at least one of the two fields is non-blank (i.e. custom mode is in use).
    private var customResolutionInvalid: Bool {
        guard case .structured(let settings) = workingPreset.kind else { return false }
        let w = settings.customWidth.trimmingCharacters(in: .whitespaces)
        let h = settings.customHeight.trimmingCharacters(in: .whitespaces)
        guard !w.isEmpty || !h.isEmpty else { return false }
        guard let wi = Int(w), let hi = Int(h), wi > 0, hi > 0, wi % 2 == 0, hi % 2 == 0 else { return true }
        return false
    }

    private var maxSizeModeActive: Bool {
        if case .structured(let settings) = workingPreset.kind {
            return !settings.maxFileSizeMB.trimmingCharacters(in: .whitespaces).isEmpty
        }
        return false
    }

    // Max File Size needs each file's own duration to calculate its bitrate —
    // ffprobe runs asynchronously right when a file is queued, so this can be
    // briefly non-empty for a file added moments ago. Encode waits it out
    // rather than risk stamping a job with the wrong (or no) bitrate.
    private var pendingDurationJobs: [EncodingJob] {
        guard maxSizeModeActive else { return [] }
        return queue.jobs.filter { $0.status == .waiting && $0.sourceDurationSeconds == nil }
    }

    // Waiting jobs whose calculated bitrate falls below the recommended
    // minimum — i.e. the target size is unrealistically small for that file's
    // length. Still honored as calculated, just flagged for a quality warning.
    private var belowMinimumBitrateJobs: [EncodingJob] {
        guard maxSizeModeActive, case .structured(let settings) = workingPreset.kind else { return [] }
        return queue.jobs.filter { job in
            guard job.status == .waiting, let duration = job.sourceDurationSeconds else { return false }
            let effectiveDur = PresetConfig.effectiveDuration(for: workingPreset, sourceDuration: duration)
            return PresetConfig.calculatedBitrateMbps(settings: settings, effectiveDurationSeconds: effectiveDur)?.belowRecommendedMinimum == true
        }
    }

    // Jobs whose resolved output path would equal their input path under the
    // currently-edited settings — e.g. no suffix/filename, same extension as
    // source, writing back into the source folder. Encoding into that path
    // would try to overwrite the input while ffmpeg is still reading it.
    private var collidingJobs: [EncodingJob] {
        guard !useCustomOutput || outputDirectory != nil else { return [] }
        let outDir  = useCustomOutput ? outputDirectory : nil
        let name    = outputFileName.trimmingCharacters(in: .whitespaces)
        let suffix  = outputSuffix.trimmingCharacters(in: .whitespaces)
        return queue.jobs.filter { job in
            guard job.status == .waiting else { return false }
            let resolved = EncodingJob.resolvedOutputURL(
                inputURL: job.inputURL,
                preset: workingPreset,
                outputDirectory: outDir,
                customFileName: name,
                customSuffix: suffix,
                sourceRelativeDirectory: job.sourceRelativeDirectory
            )
            return resolved == job.inputURL
        }
    }

    // Live estimate under the currently-edited settings — only meaningful while
    // a job is still Waiting (job.preset isn't stamped with real settings until
    // encoding starts, and duration is fetched asynchronously when queued).
    private func estimatedOutputBytes(for job: EncodingJob) -> Int64? {
        guard job.status == .waiting, let duration = job.sourceDurationSeconds else { return nil }
        let effective = PresetConfig.effectivePreset(for: workingPreset, sourceDurationSeconds: duration)
        return PresetConfig.estimatedOutputBytes(preset: effective, sourceDurationSeconds: duration)
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 16) {
                    EncodeOptionsView(
                        workingPreset: $workingPreset,
                        presetStore: presetStore,
                        useCustomOutput: $useCustomOutput,
                        outputDirectory: $outputDirectory,
                        outputFileName: $outputFileName,
                        outputSuffix: $outputSuffix,
                        onReset: resetAll
                    )

                    GroupBox {
                        ZStack {
                            if queue.jobs.isEmpty {
                                emptyState
                            } else {
                                LazyVStack(spacing: 4) {
                                    ForEach(queue.jobs) { job in
                                        JobRowView(
                                            job: job,
                                            estimatedOutputBytes: estimatedOutputBytes(for: job),
                                            onRemove: { queue.remove(job) }
                                        )
                                    }
                                }
                            }

                            // Drop overlay
                            if isDropTargeted {
                                RoundedRectangle(cornerRadius: 8)
                                    .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 2, dash: [6]))
                                    .background(Color.accentColor.opacity(0.06).clipShape(RoundedRectangle(cornerRadius: 8)))
                                    .overlay(
                                        VStack(spacing: 6) {
                                            Image(systemName: "plus.circle.fill")
                                                .font(.title)
                                                .foregroundColor(.accentColor)
                                            Text("Drop to add to queue")
                                                .font(.callout.weight(.medium))
                                                .foregroundColor(.accentColor)
                                        }
                                    )
                            }
                        }
                        .onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in
                            handleDrop(providers: providers)
                        }
                    } label: {
                        HStack {
                            Text("Queue").font(.headline)
                            Spacer()
                            if !queue.jobs.isEmpty {
                                Button("Clear completed") { queue.removeCompleted() }
                                    .buttonStyle(.plain)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .disabled(queue.isRunning)
                            }
                        }
                    }
                }
                .padding(16)
            }

            if customResolutionInvalid {
                Divider()
                Label(
                    "Custom resolution needs valid Width and Height values, both even numbers.",
                    systemImage: "exclamationmark.triangle.fill"
                )
                .font(.caption)
                .foregroundStyle(.orange)
                .padding(.horizontal, 20)
                .padding(.top, 8)
            }

            if !collidingJobs.isEmpty {
                Divider()
                Label(
                    "Output would overwrite \(collidingJobs.count) input file\(collidingJobs.count == 1 ? "" : "s") — add a suffix, filename, or choose a different output folder.",
                    systemImage: "exclamationmark.triangle.fill"
                )
                .font(.caption)
                .foregroundStyle(.orange)
                .padding(.horizontal, 20)
                .padding(.top, 8)
            }

            if !pendingDurationJobs.isEmpty {
                Divider()
                Label(
                    "Waiting for file info on \(pendingDurationJobs.count) file\(pendingDurationJobs.count == 1 ? "" : "s") before Max File Size can calculate a bitrate…",
                    systemImage: "clock"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 20)
                .padding(.top, 8)
            } else if !belowMinimumBitrateJobs.isEmpty {
                Divider()
                Label(
                    "\(belowMinimumBitrateJobs.count) file\(belowMinimumBitrateJobs.count == 1 ? "" : "s") require a bitrate below \(String(format: "%.1f", PresetConfig.recommendedMinimumMbps)) Mbps to hit this target — quality may suffer.",
                    systemImage: "exclamationmark.triangle.fill"
                )
                .font(.caption)
                .foregroundStyle(.orange)
                .padding(.horizontal, 20)
                .padding(.top, 8)
            }

            Divider()

            HStack(spacing: 10) {
                Button("Add Files…") { addFiles() }
                    .buttonStyle(.bordered)
                    .disabled(queue.isRunning)
                Spacer()
                if queue.isRunning {
                    Button("Cancel") { queue.cancel() }
                        .buttonStyle(.bordered)
                        .tint(.red)
                } else {
                    Button("Encode") { startEncoding() }
                        .buttonStyle(.borderedProminent)
                        .disabled(!canStart)
                        .keyboardShortcut(.return, modifiers: .command)
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .background(.bar)
        }
        .frame(minWidth: 580, idealWidth: 700, minHeight: 480, idealHeight: 790)
        .onAppear {
            if !launchURLs.urls.isEmpty {
                enqueueURLs(launchURLs.urls)
                launchURLs.urls = []
            }
        }
    }

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "tray")
                .font(.largeTitle)
                .foregroundStyle(.tertiary)
            Text("No files in queue")
                .foregroundStyle(.secondary)
            Text("Add files below, or right-click video files in Finder")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 30)
    }

    // MARK: - Actions

    private func addFiles() {
        let panel = NSOpenPanel()
        panel.canChooseFiles           = true
        panel.canChooseDirectories     = true
        panel.allowsMultipleSelection  = true
        panel.allowedContentTypes      = [.movie, .video, .mpeg4Movie, .quickTimeMovie]
        panel.prompt = "Add to Queue"
        if panel.runModal() == .OK { enqueueURLs(panel.urls) }
    }

    func enqueueURLs(_ urls: [URL]) {
        queue.add(urls: urls)
    }

    // Accepts both files and folders — EncodingQueue.add expands any folder into
    // the video files it contains (recursively), so a dropped folder just needs
    // to pass through here unfiltered.
    private func handleDrop(providers: [NSItemProvider]) -> Bool {
        var handled = false
        for provider in providers {
            provider.loadItem(forTypeIdentifier: "public.file-url", options: nil) { item, _ in
                guard let data = item as? Data,
                      let url  = URL(dataRepresentation: data, relativeTo: nil) else { return }
                var isDirectory: ObjCBool = false
                let exists = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
                guard exists, isDirectory.boolValue || EncodingQueue.videoExtensions.contains(url.pathExtension.lowercased()) else { return }
                DispatchQueue.main.async {
                    self.enqueueURLs([url])
                }
            }
            handled = true
        }
        return handled
    }

    // Preset settings no longer need resetting here — reselecting a preset (or
    // the "Discard Edits" action in EncodeOptionsView) already reloads its
    // canonical stored settings. This just clears the queue and output naming.
    private func resetAll() {
        useCustomOutput   = false
        outputDirectory   = nil
        outputFileName    = ""
        outputSuffix      = ""
        queue.clear()
    }

    private func startEncoding() {
        let outDir = useCustomOutput ? outputDirectory : nil

        queue.start(
            preset: workingPreset,
            outputDirectory: outDir,
            outputFileName: outputFileName.trimmingCharacters(in: .whitespaces),
            outputSuffix: outputSuffix.trimmingCharacters(in: .whitespaces)
        )
    }
}
