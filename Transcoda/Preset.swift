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

    // h264Mp4 only. If set to a valid positive number (MB), bitrateMbps is
    // superseded — the actual encode bitrate is calculated per file from this
    // target size and each file's own duration. Blank/invalid means unused
    // (manual bitrateMbps applies as normal). See PresetConfig.effectivePreset.
    var maxFileSizeMB: String = ""

    // Shared by both codec families (same Resolution row). If both are valid
    // positive even integers, they override the Resolution picker entirely —
    // used for -vf scale=WxH instead of resolution.ffmpegValue. Must be even:
    // yuv420p chroma subsampling halves each dimension, so an odd value fails
    // the encode outright. Toggled via clicking the "Resolution" label in
    // EncodeOptionsView; switching back to the picker clears both.
    var customWidth: String = ""
    var customHeight: String = ""

    // Shared by both codec families (same Frame Rate row). If a valid positive
    // number, overrides the Frame Rate picker for -r <value> — unlike
    // width/height, decimals are valid (e.g. 23.976) and the raw typed string
    // is passed straight through, matching Trim Start's convention. Toggled
    // via clicking the "Frame Rate" label; switching back to the picker
    // clears it.
    var customFramerate: String = ""

    // Shared by both codec families. When true, all audio options are
    // disabled and the output has no audio track at all (-an) instead of the
    // usual -c:a/-b:a/-ar/-ac flags. Toggled via clicking the "Audio" column
    // header in EncodeOptionsView.
    var muted: Bool = false

    // Explicit memberwise init — required once a custom init(from:) exists
    // below, since Swift only auto-generates the memberwise initializer when
    // no other initializer is present. Keeps every existing call site (which
    // omits the trailing string fields, relying on their defaults) working
    // unchanged.
    init(codecFamily: CodecFamily, resolution: Resolution, framerate: FrameRate, scan: ScanType,
         bitrateMbps: String, audioCodec: AudioCodec, audioBitrate: AudioBitrate,
         proResCodec: ProResCodec, audioSampleSize: AudioSampleSize, audioSampleRate: SampleRate,
         trimStartSeconds: String = "", maxFileSizeMB: String = "",
         customWidth: String = "", customHeight: String = "", customFramerate: String = "",
         muted: Bool = false) {
        self.codecFamily = codecFamily
        self.resolution = resolution
        self.framerate = framerate
        self.scan = scan
        self.bitrateMbps = bitrateMbps
        self.audioCodec = audioCodec
        self.audioBitrate = audioBitrate
        self.proResCodec = proResCodec
        self.audioSampleSize = audioSampleSize
        self.audioSampleRate = audioSampleRate
        self.trimStartSeconds = trimStartSeconds
        self.maxFileSizeMB = maxFileSizeMB
        self.customWidth = customWidth
        self.customHeight = customHeight
        self.customFramerate = customFramerate
        self.muted = muted
    }

    private enum CodingKeys: String, CodingKey {
        case codecFamily, resolution, framerate, scan, bitrateMbps, audioCodec, audioBitrate
        case proResCodec, audioSampleSize, audioSampleRate
        case trimStartSeconds, maxFileSizeMB, customWidth, customHeight, customFramerate, muted
    }

    // Custom decoder: the first 10 fields have been there since presets became
    // saveable, so they're required as normal. Everything after was added in
    // a later version — a preset saved before that field existed simply won't
    // have the key, which is expected (not corrupt data), so decodeIfPresent
    // falls back to the same default the property declares, rather than
    // failing the whole decode with keyNotFound.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        codecFamily     = try container.decode(CodecFamily.self, forKey: .codecFamily)
        resolution      = try container.decode(Resolution.self, forKey: .resolution)
        framerate       = try container.decode(FrameRate.self, forKey: .framerate)
        scan            = try container.decode(ScanType.self, forKey: .scan)
        bitrateMbps     = try container.decode(String.self, forKey: .bitrateMbps)
        audioCodec      = try container.decode(AudioCodec.self, forKey: .audioCodec)
        audioBitrate    = try container.decode(AudioBitrate.self, forKey: .audioBitrate)
        proResCodec     = try container.decode(ProResCodec.self, forKey: .proResCodec)
        audioSampleSize = try container.decode(AudioSampleSize.self, forKey: .audioSampleSize)
        audioSampleRate = try container.decode(SampleRate.self, forKey: .audioSampleRate)

        trimStartSeconds = try container.decodeIfPresent(String.self, forKey: .trimStartSeconds) ?? ""
        maxFileSizeMB    = try container.decodeIfPresent(String.self, forKey: .maxFileSizeMB) ?? ""
        customWidth      = try container.decodeIfPresent(String.self, forKey: .customWidth) ?? ""
        customHeight     = try container.decodeIfPresent(String.self, forKey: .customHeight) ?? ""
        customFramerate  = try container.decodeIfPresent(String.self, forKey: .customFramerate) ?? ""
        muted            = try container.decodeIfPresent(Bool.self, forKey: .muted) ?? false
    }

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
