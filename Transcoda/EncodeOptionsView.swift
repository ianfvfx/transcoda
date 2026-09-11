import SwiftUI
import UniformTypeIdentifiers

struct EncodeOptionsView: View {
    @Binding var workingPreset: Preset
    @ObservedObject var presetStore: PresetStore
    @Binding var useCustomOutput: Bool
    @Binding var outputDirectory: URL?
    @Binding var outputFileName: String
    @Binding var outputSuffix: String
    @Binding var frameIOProject: FrameIOProjectOption?
    @Binding var soundlayEnabled: Bool
    @Binding var soundlayAudioURL: URL?
    @Binding var soundlayAudioDuration: Double?
    var onReset: () -> Void

    @State private var showSaveAsSheet = false
    @State private var showNewPresetSheet = false
    @State private var saveAsName = ""
    @State private var newPresetName = ""
    @State private var newPresetIsStructured = true
    @State private var newPresetCodecFamily: CodecFamily = .h264Mp4
    @State private var errorMessage: String?
    @State private var showCustomResolutionFields = false
    @State private var showCustomFramerateField = false

    // Transient Frame.io UI state — the project list is re-fetched each time
    // the checkbox is ticked on, so it doesn't need to live in ContentView.
    @State private var frameIOAvailableProjects: [FrameIOProjectOption] = []
    @State private var frameIOAuthBusy = false
    @State private var frameIOErrorMessage: String?

    // Transient VidChecker UI state — fetched once per session the first
    // time the VidChecker preset is selected (no auth step, unlike Frame.io,
    // so there's no reason to defer it to a checkbox tick).
    @State private var vidCheckerTemplates: [VidCheckerTemplate] = []
    @State private var vidCheckerLoading = false
    @State private var vidCheckerLoadError: String?

    var body: some View {
        VStack(spacing: 12) {
            optionsBox
            if !isVidCheckerPreset {
                ffmpegPreviewBox
            }
        }
        .sheet(isPresented: $showSaveAsSheet) { saveAsSheet }
        .sheet(isPresented: $showNewPresetSheet) { newPresetSheet }
        .alert("Preset Error", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK") { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
        .alert("Frame.io", isPresented: Binding(
            get: { frameIOErrorMessage != nil },
            set: { if !$0 { frameIOErrorMessage = nil } }
        )) {
            Button("OK") { frameIOErrorMessage = nil }
        } message: {
            Text(frameIOErrorMessage ?? "")
        }
        .onChange(of: workingPreset.id) {
            if case .structured(let settings) = workingPreset.kind {
                showCustomResolutionFields = !settings.customWidth.isEmpty && !settings.customHeight.isEmpty
                showCustomFramerateField = !settings.customFramerate.isEmpty
            } else {
                showCustomResolutionFields = false
                showCustomFramerateField = false
            }
            if isVidCheckerPreset, vidCheckerTemplates.isEmpty, !vidCheckerLoading {
                fetchVidCheckerTemplates()
            }
        }
    }

    // MARK: - Main options box

    private var optionsBox: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                presetPickerRow
                presetActionsRow

                Divider()

                switch workingPreset.kind {
                case .structured:
                    structuredColumns
                case .advanced(let rawTemplate):
                    AdvancedTemplateEditorView(rawTemplate: Binding(
                        get: { rawTemplate },
                        set: { workingPreset.kind = .advanced(rawTemplate: $0) }
                    ))
                case .transcribe:
                    transcribeNote
                case .vidchecker:
                    vidCheckerTemplateRow
                }

                // VidChecker has no output settings at all — it produces no
                // local file, so there's nothing for File Name/Suffix/folder
                // location to apply to. The template picker above is the
                // only thing this preset needs.
                if !isVidCheckerPreset {
                    Divider()
                    outputSection
                }

            }
            .padding(10)
        } label: {
            HStack {
                Text("Encoding Options")
                    .font(.headline)
                Spacer()
                Button(action: onReset) {
                    Label("Clear", systemImage: "arrow.counterclockwise")
                        .font(.caption)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
    }

    // MARK: - Preset picker + actions

    private var presetSelectionBinding: Binding<UUID> {
        Binding(
            get: { workingPreset.id },
            set: { newId in
                if let canonical = presetStore.canonicalCopy(for: newId) {
                    workingPreset = canonical
                    // Transcribe SRTs only exposes folder location — File
                    // Name/Suffix are hidden for it, so clear any leftover
                    // value from a previously-selected preset rather than
                    // letting it silently keep applying while out of view.
                    if case .transcribe = canonical.kind {
                        outputFileName = ""
                        outputSuffix = ""
                    }
                }
            }
        )
    }

    private var presetPickerRow: some View {
        HStack(spacing: 10) {
            Text("Preset")
                .frame(width: 80, alignment: .leading)
                .foregroundStyle(.secondary)
                .font(.callout)
            Picker("", selection: presetSelectionBinding) {
                Section("Video Encodes") {
                    ForEach(videoEncodePresets) { p in Text(p.name).tag(p.id) }
                }
                Section("Utilities") {
                    ForEach(utilityPresets) { p in Text(p.name).tag(p.id) }
                }
                if !presetStore.customs.isEmpty {
                    Section("Custom") {
                        ForEach(presetStore.customs) { p in Text(p.name).tag(p.id) }
                    }
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .frame(maxWidth: .infinity, alignment: .leading)

            Image("background")
                .resizable()
                .scaledToFit()
                .frame(width: 259, height: 29)
                .allowsHitTesting(false)
        }
    }

    private var presetActionsRow: some View {
        HStack(spacing: 8) {
            Button("Discard Edits") { discardEdits() }
                .help("Reload this preset's saved settings, discarding any unsaved changes.")

            Spacer(minLength: 8)

            if workingPreset.origin == .custom {
                Button("Save") { saveCurrent() }
            }
            Button("Save As…") { presentSaveAs() }
            Button("New…") { presentNewPreset() }
            Button("Import…") { importPreset() }
            Button("Export…") { exportPreset() }
            if workingPreset.origin == .custom {
                Button("Delete", role: .destructive) { deleteCurrent() }
            }
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .font(.caption)
    }

    // MARK: - Structured settings binding

    private var structuredSettingsBinding: Binding<StructuredSettings> {
        Binding(
            get: {
                if case .structured(let s) = workingPreset.kind { return s }
                return .defaultH264MP4()
            },
            set: { workingPreset.kind = .structured($0) }
        )
    }

    private var structuredColumns: some View {
        let settings = structuredSettingsBinding
        return VStack(alignment: .leading, spacing: 10) {
            switch settings.wrappedValue.codecFamily {
            case .h264Mp4: h264Columns(settings)
            case .proRes:  proResColumns(settings)
            }
            optionRow("Trim Start") {
                HStack(spacing: 4) {
                    TextField("", text: settings.trimStartSeconds)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 55)
                    Text("sec").foregroundStyle(.secondary).font(.callout)
                }
            }
        }
    }

    // Sits at the bottom of the Audio column (both h264Columns and
    // proResColumns) below the codec/bitrate/sample-rate fields — Mute is
    // itself an audio option (same settings.muted the "Audio" column header
    // already toggles by click; this just gives it an explicit, discoverable
    // checkbox too), so it stays outside the .disabled(muted) block those
    // fields live in. The Divider here is unadorned (no horizontal padding),
    // so — sitting inside this column's own VStack rather than the HStack
    // between columns — it only splits the right-hand side, not the full row.
    private func muteAndTimecodeSection(_ settings: Binding<StructuredSettings>) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            soundlayRow(settings)
            Toggle("Mute", isOn: muteToggleBinding(settings))
                .toggleStyle(.checkbox)
                .font(.callout)
            Divider()
            Toggle("Timecode Track", isOn: settings.includeTimecodeTrack)
                .toggleStyle(.checkbox)
                .font(.callout)
        }
    }

    // Mute and Soundlay are contradictory (one says "no audio", the other
    // says "use this specific audio") — each turning on forces the other off.
    private func muteToggleBinding(_ settings: Binding<StructuredSettings>) -> Binding<Bool> {
        Binding(
            get: { settings.wrappedValue.muted },
            set: { newValue in
                settings.wrappedValue.muted = newValue
                if newValue { soundlayEnabled = false }
            }
        )
    }

    // MARK: - Soundlay

    private func soundlayToggleBinding(_ settings: Binding<StructuredSettings>) -> Binding<Bool> {
        Binding(
            get: { soundlayEnabled },
            set: { newValue in
                soundlayEnabled = newValue
                if newValue {
                    settings.wrappedValue.muted = false
                } else {
                    soundlayAudioURL = nil
                    soundlayAudioDuration = nil
                }
            }
        )
    }

    private func soundlayRow(_ settings: Binding<StructuredSettings>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Toggle("Soundlay", isOn: soundlayToggleBinding(settings))
                    .toggleStyle(.checkbox)
                    .font(.callout)
                if soundlayEnabled {
                    Button("Select Audio") { chooseSoundlayAudio() }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }
            }
            if soundlayEnabled {
                Text(soundlayAudioURL?.lastPathComponent ?? "No file selected")
                    .font(.caption)
                    .foregroundStyle(soundlayAudioURL == nil ? .red : .secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
    }

    private func chooseSoundlayAudio() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.audio]
        panel.prompt = "Select"
        guard panel.runModal() == .OK, let url = panel.urls.first else { return }
        soundlayAudioURL = url
        soundlayAudioDuration = nil
        DispatchQueue.global(qos: .utility).async {
            let duration = PresetConfig.duration(url)
            DispatchQueue.main.async {
                soundlayAudioDuration = duration > 0 ? duration : nil
            }
        }
    }

    // MARK: - Transcribe SRTs note

    private var transcribeNote: some View {
        HStack {
            Image(systemName: "waveform")
                .foregroundStyle(.tertiary)
            Text("Generates an SRT subtitle file from each source file's audio — no video is encoded.")
                .font(.callout).foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }

    // MARK: - H.264/MP4 two-column layout

    private func h264Columns(_ settings: Binding<StructuredSettings>) -> some View {
        HStack(alignment: .top, spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                columnHeader("Video")
                resolutionRow(settings)
                framerateRow(settings)
                optionRow("Bitrate") {
                    HStack(spacing: 4) {
                        TextField(StructuredSettings.defaultH264BitrateMbps, text: settings.bitrateMbps)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 55)
                            .disabled(!settings.wrappedValue.maxFileSizeMB.trimmingCharacters(in: .whitespaces).isEmpty)
                        Text("Mbps").foregroundStyle(.secondary).font(.callout)
                    }
                }
                optionRow("Max Size") {
                    HStack(spacing: 4) {
                        TextField("", text: settings.maxFileSizeMB)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 55)
                        Text("MB").foregroundStyle(.secondary).font(.callout)
                    }
                    .help("If set, calculates each file's bitrate independently to target this size, and disables the Bitrate field above.")
                }
                optionRow("Scan") {
                    Picker("", selection: settings.scan) {
                        ForEach(ScanType.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.menu).labelsHidden()
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Divider().padding(.horizontal, 12)

            VStack(alignment: .leading, spacing: 10) {
                audioColumnHeader(settings)
                VStack(alignment: .leading, spacing: 10) {
                    optionRow("Codec") {
                        Picker("", selection: settings.audioCodec) {
                            ForEach(AudioCodec.allCases) { Text($0.rawValue).tag($0) }
                        }
                        .pickerStyle(.menu).labelsHidden()
                    }
                    if settings.wrappedValue.audioCodec.usesBitrate {
                        optionRow("Bitrate") {
                            Picker("", selection: settings.audioBitrate) {
                                ForEach(AudioBitrate.allCases) { Text($0.label).tag($0) }
                            }
                            .pickerStyle(.menu).labelsHidden()
                        }
                    }
                    optionRow("Sample Rate") {
                        Picker("", selection: settings.audioSampleRate) {
                            ForEach(SampleRate.allCases) { Text($0.label).tag($0) }
                        }
                        .pickerStyle(.menu).labelsHidden()
                    }
                }
                .disabled(settings.wrappedValue.muted)
                .opacity(settings.wrappedValue.muted ? 0.4 : 1)

                muteAndTimecodeSection(settings)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - ProRes two-column layout

    private func proResColumns(_ settings: Binding<StructuredSettings>) -> some View {
        HStack(alignment: .top, spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                columnHeader("Video")
                optionRow("Codec") {
                    Picker("", selection: settings.proResCodec) {
                        ForEach(ProResCodec.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.menu).labelsHidden()
                }
                resolutionRow(settings)
                framerateRow(settings)
                optionRow("Scan") {
                    Picker("", selection: settings.scan) {
                        ForEach(ScanType.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.menu).labelsHidden()
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Divider().padding(.horizontal, 12)

            VStack(alignment: .leading, spacing: 10) {
                audioColumnHeader(settings)
                VStack(alignment: .leading, spacing: 10) {
                    optionRow("Sample Size") {
                        Picker("", selection: settings.audioSampleSize) {
                            ForEach(AudioSampleSize.allCases) { Text($0.rawValue).tag($0) }
                        }
                        .pickerStyle(.menu).labelsHidden()
                    }
                    optionRow("Sample Rate") {
                        Picker("", selection: settings.audioSampleRate) {
                            ForEach(SampleRate.allCases) { Text($0.label).tag($0) }
                        }
                        .pickerStyle(.menu).labelsHidden()
                    }
                }
                .disabled(settings.wrappedValue.muted)
                .opacity(settings.wrappedValue.muted ? 0.4 : 1)

                muteAndTimecodeSection(settings)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - Output section

    private enum OutputLocation: Hashable {
        case sameAsSource, downloads, desktop, other
    }

    private var downloadsURL: URL {
        FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first!
    }

    private var desktopURL: URL {
        FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first!
    }

    private var selectedLocation: OutputLocation {
        guard useCustomOutput else { return .sameAsSource }
        // "Other" selected but no folder chosen yet still counts as .other, not
        // .sameAsSource — otherwise the checkbox immediately un-checks itself and
        // the Choose… button (gated on .other) never appears.
        guard let dir = outputDirectory else { return .other }
        let path = dir.standardizedFileURL.path
        if path == downloadsURL.standardizedFileURL.path { return .downloads }
        if path == desktopURL.standardizedFileURL.path { return .desktop }
        return .other
    }

    private func selectLocation(_ location: OutputLocation) {
        switch location {
        case .sameAsSource:
            useCustomOutput = false
            outputDirectory = nil
        case .downloads:
            useCustomOutput = true
            outputDirectory = downloadsURL
        case .desktop:
            useCustomOutput = true
            outputDirectory = desktopURL
        case .other:
            useCustomOutput = true
        }
    }

    private func locationToggle(_ label: String, _ location: OutputLocation) -> some View {
        Toggle(label, isOn: Binding(
            get: { selectedLocation == location },
            set: { isOn in if isOn { selectLocation(location) } }
        ))
        .toggleStyle(.checkbox)
        .font(.callout)
    }

    private var outputSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            columnHeader("Output")

            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 16) {
                    locationToggle("Same as Source", .sameAsSource)
                    locationToggle("Downloads", .downloads)
                    locationToggle("Desktop", .desktop)
                    locationToggle("Other", .other)
                }

                if useCustomOutput {
                    HStack(spacing: 8) {
                        Text(outputDirectory?.path ?? "No folder selected")
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(outputDirectory == nil ? .red : .secondary)
                            .lineLimit(1)
                            .truncationMode(.head)
                        if selectedLocation == .other {
                            Button("Choose…") { chooseFolder() }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                        }
                    }
                }
            }

            // File name and suffix — mutually exclusive. Not shown for
            // Transcribe SRTs, which only exposes folder location; the .srt
            // always takes the input file's own stem (matching
            // transcribeSRTs.py's own default naming).
            if !isTranscribePreset {
                frameIOUploadRow

                HStack(alignment: .top, spacing: 0) {
                    VStack(alignment: .leading, spacing: 10) {
                        columnHeader("File Name")
                        TextField("Same as source", text: Binding(
                            get: { outputFileName },
                            set: { newVal in
                                outputFileName = newVal
                                if !newVal.isEmpty { outputSuffix = "" }
                            }
                        ))
                        .textFieldStyle(.roundedBorder)
                        .disabled(!outputSuffix.isEmpty)
                        .opacity(outputSuffix.isEmpty ? 1 : 0.4)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    Divider().padding(.horizontal, 12)

                    VStack(alignment: .leading, spacing: 10) {
                        columnHeader("Suffix")
                        TextField(workingPreset.outputSuffix, text: Binding(
                            get: { outputSuffix },
                            set: { newVal in
                                outputSuffix = newVal
                                if !newVal.isEmpty { outputFileName = "" }
                            }
                        ))
                        .textFieldStyle(.roundedBorder)
                        .disabled(!outputFileName.isEmpty)
                        .opacity(outputFileName.isEmpty ? 1 : 0.4)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    private var isTranscribePreset: Bool {
        if case .transcribe = workingPreset.kind { return true }
        return false
    }

    private var isVidCheckerPreset: Bool {
        if case .vidchecker = workingPreset.kind { return true }
        return false
    }

    // Built-ins split into two picker sections by kind — exhaustive switches
    // so a future new PresetKind case forces a decision here rather than
    // silently vanishing from both groups.
    private var videoEncodePresets: [Preset] {
        presetStore.builtIns.filter {
            switch $0.kind {
            case .structured, .advanced: return true
            case .transcribe, .vidchecker: return false
            }
        }
    }

    private var utilityPresets: [Preset] {
        presetStore.builtIns.filter {
            switch $0.kind {
            case .transcribe, .vidchecker: return true
            case .structured, .advanced: return false
            }
        }
    }

    // MARK: - VidChecker

    private var vidCheckerTemplateIdBinding: Binding<Int?> {
        Binding(
            get: {
                if case .vidchecker(let templateId) = workingPreset.kind { return templateId }
                return nil
            },
            set: { newValue in
                workingPreset.kind = .vidchecker(templateId: newValue)
            }
        )
    }

    private var vidCheckerTemplateRow: some View {
        HStack(spacing: 8) {
            Text("Template")
                .frame(width: 90, alignment: .leading)
                .foregroundStyle(.secondary)
                .font(.callout)

            if vidCheckerLoading {
                ProgressView().controlSize(.small)
            } else if let vidCheckerLoadError {
                Text(vidCheckerLoadError)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(2)
                Button("Retry") { fetchVidCheckerTemplates() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            } else {
                Picker("", selection: vidCheckerTemplateIdBinding) {
                    Text("Select…").tag(Int?.none)
                    ForEach(vidCheckerTemplates) { template in
                        Text(template.name).tag(Int?.some(template.id))
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
            }
        }
        .padding(.vertical, 4)
    }

    private func fetchVidCheckerTemplates() {
        vidCheckerLoading = true
        vidCheckerLoadError = nil
        VidCheckerAPIClient.shared.listTemplates { result in
            DispatchQueue.main.async {
                vidCheckerLoading = false
                switch result {
                case .success(let templates):
                    vidCheckerTemplates = templates.sorted { $0.name < $1.name }
                case .failure(let error):
                    vidCheckerLoadError = error.localizedDescription
                }
            }
        }
    }

    // MARK: - Frame.io upload

    private var frameIOUploadRow: some View {
        HStack(spacing: 8) {
            Toggle("Upload to Frame.io", isOn: frameIOToggleBinding)
                .toggleStyle(.checkbox)
                .font(.callout)

            if frameIOAuthBusy {
                ProgressView()
                    .controlSize(.small)
            } else if frameIOProject != nil && !frameIOAvailableProjects.isEmpty {
                Picker("", selection: frameIOProjectSelectionBinding) {
                    ForEach(frameIOAvailableProjects) { option in
                        Text(option.project.name).tag(option.id)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .frame(maxWidth: 220)
            }
        }
        .disabled(frameIOAuthBusy)
        .padding(.bottom, 4)
    }

    // Ticking on doesn't flip frameIOProject directly — it stays nil (box
    // unchecked) until sign-in and the project fetch both succeed, so a
    // cancelled/failed login can't leave the box checked with nothing behind
    // it. Ticking off clears everything immediately.
    private var frameIOToggleBinding: Binding<Bool> {
        Binding(
            get: { frameIOProject != nil || frameIOAuthBusy },
            set: { isOn in
                if isOn {
                    beginFrameIOAuthAndFetch()
                } else {
                    frameIOProject = nil
                    frameIOAvailableProjects = []
                }
            }
        )
    }

    private var frameIOProjectSelectionBinding: Binding<String> {
        Binding(
            get: { frameIOProject?.id ?? "" },
            set: { newID in
                frameIOProject = frameIOAvailableProjects.first { $0.id == newID }
            }
        )
    }

    private func beginFrameIOAuthAndFetch() {
        frameIOAuthBusy = true
        // FrameIOAuthManager is @MainActor-isolated; hop explicitly since this
        // plain view method isn't itself actor-isolated.
        Task { @MainActor in
            FrameIOAuthManager.shared.ensureAuthenticated { result in
                switch result {
                case .failure(let error):
                    DispatchQueue.main.async {
                        self.frameIOAuthBusy = false
                        self.frameIOErrorMessage = error.localizedDescription
                    }
                case .success:
                    FrameIOAPIClient.shared.fetchAccessibleProjects { result in
                        DispatchQueue.main.async {
                            self.frameIOAuthBusy = false
                            switch result {
                            case .failure(let error):
                                self.frameIOErrorMessage = error.localizedDescription
                            case .success(let projects):
                                self.frameIOAvailableProjects = projects
                                self.frameIOProject = projects.first
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: - FFmpeg preview

    private var ffmpegPreviewBox: some View {
        GroupBox {
            ScrollView(.horizontal, showsIndicators: false) {
                Text(previewString)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(6)
            }
        } label: {
            Label(
                isTranscribePreset ? "Transcribe Command" : "FFmpeg Parameters",
                systemImage: isTranscribePreset ? "waveform" : "terminal"
            )
            .font(.headline)
        }
    }

    // MARK: - Save / Save As / New / Import / Export / Delete sheets & actions

    private var saveAsSheet: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Save As New Preset").font(.headline)
            TextField("Preset name", text: $saveAsName)
                .textFieldStyle(.roundedBorder)
            HStack {
                Spacer()
                Button("Cancel") { showSaveAsSheet = false }
                Button("Save") {
                    performSaveAs()
                }
                .buttonStyle(.borderedProminent)
                .disabled(saveAsName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 320)
    }

    private var newPresetSheet: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("New Preset").font(.headline)
            TextField("Preset name", text: $newPresetName)
                .textFieldStyle(.roundedBorder)

            Picker("Kind", selection: $newPresetIsStructured) {
                Text("Structured").tag(true)
                Text("Advanced (raw ffmpeg)").tag(false)
            }
            .pickerStyle(.segmented)

            if newPresetIsStructured {
                Picker("Codec", selection: $newPresetCodecFamily) {
                    ForEach(CodecFamily.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.menu)
            }

            HStack {
                Spacer()
                Button("Cancel") { showNewPresetSheet = false }
                Button("Create") {
                    performCreateNewPreset()
                }
                .buttonStyle(.borderedProminent)
                .disabled(newPresetName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 340)
    }

    private func discardEdits() {
        if let canonical = presetStore.canonicalCopy(for: workingPreset.id) {
            workingPreset = canonical
        }
    }

    // If a suffix is currently typed in the Output section (overriding the
    // preset's own default for this session), saving bakes it in as the
    // preset's new default going forward — same role Clearcast MP4's built-in
    // "_CC" plays. Falls back to the preset's existing suffix when the live
    // field is blank, so saving without touching it doesn't erase anything.
    private var suffixToPersist: String {
        let live = outputSuffix.trimmingCharacters(in: .whitespaces)
        return live.isEmpty ? workingPreset.outputSuffix : live
    }

    private func saveCurrent() {
        var toSave = workingPreset
        toSave.outputSuffix = suffixToPersist
        do {
            try presetStore.save(toSave)
            workingPreset = toSave
            outputSuffix = ""   // now the preset's own default, shown via placeholder
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func presentSaveAs() {
        saveAsName = workingPreset.origin == .builtIn ? "\(workingPreset.name) Copy" : workingPreset.name
        showSaveAsSheet = true
    }

    private func performSaveAs() {
        let name = saveAsName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        do {
            let saved = try presetStore.saveAsNew(
                name: name,
                kind: workingPreset.kind,
                outputExtension: workingPreset.outputExtension,
                outputSuffix: suffixToPersist
            )
            workingPreset = saved
            outputSuffix = ""   // now the preset's own default, shown via placeholder
            showSaveAsSheet = false
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func presentNewPreset() {
        newPresetName = ""
        newPresetIsStructured = true
        newPresetCodecFamily = .h264Mp4
        showNewPresetSheet = true
    }

    private func performCreateNewPreset() {
        let name = newPresetName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }

        let kind: PresetKind
        let ext: String
        if newPresetIsStructured {
            switch newPresetCodecFamily {
            case .h264Mp4:
                kind = .structured(.defaultH264MP4())
                ext = "mp4"
            case .proRes:
                kind = .structured(.defaultProRes())
                ext = "mov"
            }
        } else {
            kind = .advanced(rawTemplate: "-y -i {input} -c:v libx264 -c:a aac {output}")
            ext = "mp4"
        }
        let suffix = "_" + name.replacingOccurrences(of: " ", with: "")

        do {
            let created = try presetStore.saveAsNew(name: name, kind: kind, outputExtension: ext, outputSuffix: suffix)
            workingPreset = created
            showNewPresetSheet = false
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func deleteCurrent() {
        do {
            try presetStore.delete(id: workingPreset.id)
            workingPreset = BuiltInPresets.mp4
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func exportPreset() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.xml]
        panel.nameFieldStringValue = workingPreset.name + ".xml"
        if panel.runModal() == .OK, let url = panel.url {
            do {
                try presetStore.export(workingPreset, to: url)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func importPreset() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.xml]
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            do {
                let imported = try presetStore.importPreset(from: url)
                workingPreset = imported
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    // MARK: - Helpers

    private func columnHeader(_ title: String) -> some View {
        Text(title)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.primary)
    }

    // Clicking "Audio" toggles mute — no separate reveal/hide UI like
    // Resolution/Frame Rate since there's no value to enter, just an on/off
    // state. The options below are disabled/dimmed by the caller.
    private func audioColumnHeader(_ settings: Binding<StructuredSettings>) -> some View {
        Button {
            settings.wrappedValue.muted.toggle()
        } label: {
            Text(settings.wrappedValue.muted ? "Audio (Muted)" : "Audio")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)
        }
        .buttonStyle(.plain)
        .help(settings.wrappedValue.muted ? "Click to re-enable audio" : "Click to encode without audio")
    }

    private func optionRow<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 8) {
            Text(label)
                .frame(width: 90, alignment: .leading)
                .foregroundStyle(.secondary)
                .font(.callout)
                .lineLimit(1)
            content()
        }
    }

    // Clicking the "Resolution" label toggles between the preset dropdown and
    // two Width/Height fields for an arbitrary custom resolution. Switching
    // back to the dropdown clears both fields rather than just hiding them.
    private func resolutionRow(_ settings: Binding<StructuredSettings>) -> some View {
        HStack(spacing: 8) {
            Button {
                showCustomResolutionFields.toggle()
                if !showCustomResolutionFields {
                    settings.wrappedValue.customWidth = ""
                    settings.wrappedValue.customHeight = ""
                }
            } label: {
                Text("Resolution")
                    .frame(width: 90, alignment: .leading)
                    .foregroundStyle(.secondary)
                    .font(.callout)
                    .lineLimit(1)
            }
            .buttonStyle(.plain)
            .help(showCustomResolutionFields ? "Switch back to resolution presets" : "Enter a custom width & height")

            if showCustomResolutionFields {
                HStack(spacing: 4) {
                    TextField("Width", text: settings.customWidth)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 60)
                    Text("×").foregroundStyle(.secondary)
                    TextField("Height", text: settings.customHeight)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 60)
                }
            } else {
                Picker("", selection: settings.resolution) {
                    ForEach(Resolution.allCases) { res in
                        Text(resolutionLabel(res)).tag(res)
                    }
                }
                .pickerStyle(.menu).labelsHidden()
            }
        }
    }

    // Same clickable-label pattern as resolutionRow — decimals are meaningful
    // for frame rate (23.976, 29.97), so the field has no width/height-style
    // even/odd constraint.
    private func framerateRow(_ settings: Binding<StructuredSettings>) -> some View {
        HStack(spacing: 8) {
            Button {
                showCustomFramerateField.toggle()
                if !showCustomFramerateField {
                    settings.wrappedValue.customFramerate = ""
                }
            } label: {
                Text("Frame Rate")
                    .frame(width: 90, alignment: .leading)
                    .foregroundStyle(.secondary)
                    .font(.callout)
                    .lineLimit(1)
            }
            .buttonStyle(.plain)
            .help(showCustomFramerateField ? "Switch back to frame rate presets" : "Enter a custom frame rate")

            if showCustomFramerateField {
                HStack(spacing: 4) {
                    TextField("fps", text: settings.customFramerate)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 60)
                    Text("fps").foregroundStyle(.secondary).font(.callout)
                }
            } else {
                Picker("", selection: settings.framerate) {
                    ForEach(FrameRate.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.menu).labelsHidden()
            }
        }
    }

    private var previewString: String {
        PresetConfig.previewString(for: workingPreset, soundlayAudioURL: soundlayEnabled ? soundlayAudioURL : nil)
    }

    private func resolutionLabel(_ res: Resolution) -> AttributedString {
        guard let ar = res.aspectRatio else {
            return AttributedString(res.label)
        }
        var ratio = AttributedString(ar)
        ratio.foregroundColor = .secondaryLabelColor
        return AttributedString(res.label) + AttributedString("   ") + ratio
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories    = true
        panel.canChooseFiles          = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Select Output Folder"
        if panel.runModal() == .OK { outputDirectory = panel.url }
    }
}
