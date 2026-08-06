import SwiftUI
import UniformTypeIdentifiers

struct EncodeOptionsView: View {
    @Binding var workingPreset: Preset
    @ObservedObject var presetStore: PresetStore
    @Binding var useCustomOutput: Bool
    @Binding var outputDirectory: URL?
    @Binding var outputFileName: String
    @Binding var outputSuffix: String
    var onReset: () -> Void

    @State private var showSaveAsSheet = false
    @State private var showNewPresetSheet = false
    @State private var saveAsName = ""
    @State private var newPresetName = ""
    @State private var newPresetIsStructured = true
    @State private var newPresetCodecFamily: CodecFamily = .h264Mp4
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 12) {
            optionsBox
            ffmpegPreviewBox
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
                }

                Divider()
                outputSection

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
                Section("Built-in") {
                    ForEach(presetStore.builtIns) { p in Text(p.name).tag(p.id) }
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

    // MARK: - H.264/MP4 two-column layout

    private func h264Columns(_ settings: Binding<StructuredSettings>) -> some View {
        HStack(alignment: .top, spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                columnHeader("Video")
                optionRow("Resolution") {
                    Picker("", selection: settings.resolution) {
                        ForEach(Resolution.allCases) { res in
                            Text(resolutionLabel(res)).tag(res)
                        }
                    }
                    .pickerStyle(.menu).labelsHidden()
                }
                optionRow("Frame Rate") {
                    Picker("", selection: settings.framerate) {
                        ForEach(FrameRate.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.menu).labelsHidden()
                }
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
                columnHeader("Audio")
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
                optionRow("Resolution") {
                    Picker("", selection: settings.resolution) {
                        ForEach(Resolution.allCases) { res in
                            Text(resolutionLabel(res)).tag(res)
                        }
                    }
                    .pickerStyle(.menu).labelsHidden()
                }
                optionRow("Frame Rate") {
                    Picker("", selection: settings.framerate) {
                        ForEach(FrameRate.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.menu).labelsHidden()
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
                columnHeader("Audio")
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

            // File name and suffix — mutually exclusive
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
            Label("FFmpeg Parameters", systemImage: "terminal")
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

    private func saveCurrent() {
        do {
            try presetStore.save(workingPreset)
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
                outputSuffix: workingPreset.outputSuffix
            )
            workingPreset = saved
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

    private var previewString: String {
        PresetConfig.previewString(for: workingPreset)
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
