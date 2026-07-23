import Foundation

// MARK: - Provenance

enum PresetOrigin: String, Codable {
    case builtIn
    case custom
}

// MARK: - Structured settings (generalizes the old MP4Options/ProResOptions)

enum CodecFamily: String, Codable, CaseIterable, Identifiable {
    case h264Mp4 = "H.264 (MP4)"
    case proRes  = "Apple ProRes"
    var id: String { rawValue }
}

struct StructuredSettings: Codable, Equatable {
    var codecFamily: CodecFamily
    var resolution: Resolution
    var framerate: FrameRate
    var scan: ScanType

    // h264Mp4 only
    var bitrateMbps: String
    var audioCodec: AudioCodec
    var audioBitrate: AudioBitrate

    // proRes only
    var proResCodec: ProResCodec
    var audioSampleSize: AudioSampleSize

    // shared
    var audioSampleRate: SampleRate

    // If set to a valid number of seconds, seeks that far into the source before
    // encoding (-ss <value> before -i). Blank/invalid means no trim.
    var trimStartSeconds: String = ""

    // Used both as the Bitrate field's placeholder and as the actual fallback
    // value when the field is left blank — see PresetConfig.effectiveBitrateMbps.
    static let defaultH264BitrateMbps = "18"

    static func defaultH264MP4() -> StructuredSettings {
        StructuredSettings(
            codecFamily: .h264Mp4,
            resolution: .source,
            framerate: .source,
            scan: .autoDetect,
            bitrateMbps: defaultH264BitrateMbps,
            audioCodec: .aac,
            audioBitrate: .k192,
            proResCodec: .hq422,
            audioSampleSize: .bit24,
            audioSampleRate: .hz48000
        )
    }

    static func defaultProRes() -> StructuredSettings {
        StructuredSettings(
            codecFamily: .proRes,
            resolution: .source,
            framerate: .source,
            scan: .autoDetect,
            bitrateMbps: "40",
            audioCodec: .aac,
            audioBitrate: .k320,
            proResCodec: .hq422,
            audioSampleSize: .bit24,
            audioSampleRate: .hz48000
        )
    }
}

// MARK: - Preset kind

enum PresetKind: Codable, Equatable {
    case structured(StructuredSettings)
    case advanced(rawTemplate: String)   // tokens: {input}, {output}
}

// MARK: - Preset

struct Preset: Codable, Identifiable, Equatable {
    var id: UUID
    var name: String
    var origin: PresetOrigin
    var kind: PresetKind
    var outputExtension: String
    var outputSuffix: String
}
