import Foundation
import Combine

// Decodes an array element independently — a failure is captured as `nil`
// rather than propagated, so it can't abort decoding of the rest of the
// array. See PresetStore.loadCustoms.
private struct FailableDecodable<Base: Decodable>: Decodable {
    let value: Base?
    init(from decoder: Decoder) throws {
        value = try? Base(from: decoder)
    }
}

enum PresetStoreError: LocalizedError {
    case cannotOverwriteBuiltIn
    case cannotDeleteBuiltIn
    case notFound

    var errorDescription: String? {
        switch self {
        case .cannotOverwriteBuiltIn: return "Built-in presets can't be overwritten. Use Save As instead."
        case .cannotDeleteBuiltIn:    return "Built-in presets can't be deleted."
        case .notFound:               return "Preset not found."
        }
    }
}

@MainActor
final class PresetStore: ObservableObject {
    static let shared = PresetStore()

    @Published private(set) var builtIns: [Preset] = BuiltInPresets.all
    @Published private(set) var customs: [Preset] = []

    var allPresets: [Preset] { builtIns + customs }

    private let presetsDirectory: URL
    private let customsIndexFile: URL

    init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        presetsDirectory = appSupport.appendingPathComponent("Transcoda/Presets", isDirectory: true)
        customsIndexFile = presetsDirectory.appendingPathComponent("index.plist")
        try? FileManager.default.createDirectory(at: presetsDirectory, withIntermediateDirectories: true)
        loadCustoms()
    }

    // MARK: - Lookup

    func preset(id: UUID) -> Preset? {
        allPresets.first { $0.id == id }
    }

    /// Always the pristine stored/factory copy — used whenever a preset is
    /// (re)selected in the UI, so any unsaved in-session edits are discarded.
    func canonicalCopy(for id: UUID) -> Preset? {
        preset(id: id)
    }

    // MARK: - Save / Save As

    func save(_ preset: Preset) throws {
        guard preset.origin == .custom else { throw PresetStoreError.cannotOverwriteBuiltIn }
        guard let idx = customs.firstIndex(where: { $0.id == preset.id }) else {
            throw PresetStoreError.notFound
        }
        customs[idx] = preset
        try persistCustoms()
    }

    @discardableResult
    func saveAsNew(name: String, kind: PresetKind, outputExtension: String, outputSuffix: String) throws -> Preset {
        let uniqueName = uniqueCustomName(for: name)
        let new = Preset(
            id: UUID(),
            name: uniqueName,
            origin: .custom,
            kind: kind,
            outputExtension: outputExtension,
            outputSuffix: outputSuffix
        )
        customs.append(new)
        try persistCustoms()
        return new
    }

    func delete(id: UUID) throws {
        guard customs.contains(where: { $0.id == id }) else { throw PresetStoreError.cannotDeleteBuiltIn }
        customs.removeAll { $0.id == id }
        try persistCustoms()
    }

    private func uniqueCustomName(for name: String) -> String {
        let existing = Set(allPresets.map(\.name))
        guard existing.contains(name) else { return name }
        var suffix = 2
        while existing.contains("\(name) (\(suffix))") { suffix += 1 }
        return "\(name) (\(suffix))"
    }

    // MARK: - Export / Import

    func export(_ preset: Preset, to url: URL) throws {
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .xml
        let data = try encoder.encode(preset)
        try data.write(to: url, options: .atomic)
    }

    /// Imports as a NEW custom preset — always a fresh id/origin, never silently
    /// overwrites an existing entry, even if re-importing the same file.
    @discardableResult
    func importPreset(from url: URL) throws -> Preset {
        let data = try Data(contentsOf: url)
        var decoded = try PropertyListDecoder().decode(Preset.self, from: data)
        decoded.id = UUID()
        decoded.origin = .custom
        decoded.name = uniqueCustomName(for: decoded.name)
        customs.append(decoded)
        try persistCustoms()
        return decoded
    }

    // MARK: - Persistence

    // Decodes the array via FailableDecodable so one incompatible/corrupt
    // preset only loses itself, not every other saved preset — a plain
    // `[Preset].self` decode fails atomically: a single bad element throws
    // and the whole array (and every valid preset in it) is lost.
    private func loadCustoms() {
        guard let data = try? Data(contentsOf: customsIndexFile) else { return }
        guard let wrapped = try? PropertyListDecoder().decode([FailableDecodable<Preset>].self, from: data) else { return }
        let decoded = wrapped.compactMap(\.value)
        if decoded.count != wrapped.count {
            print("PresetStore: skipped \(wrapped.count - decoded.count) preset(s) that failed to decode.")
        }
        customs = decoded
    }

    private func persistCustoms() throws {
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .xml
        let data = try encoder.encode(customs)
        try data.write(to: customsIndexFile, options: .atomic)
    }
}
