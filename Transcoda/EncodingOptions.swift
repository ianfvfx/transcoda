import Foundation

// MARK: - Shared option types

enum ScanType: String, CaseIterable, Identifiable, Codable {
    case progressive   = "Progressive"
    case interlacedTFF = "Interlaced TFF"
    case autoDetect     = "Source"
    var id: String { rawValue }
}

enum Resolution: String, CaseIterable, Identifiable, Codable {
    case source       = ""
    case hd1080       = "1920x1080"
    case hd720        = "1280x720"
    case vertical1080 = "1080x1920"
    case vertical720  = "720x1280"
    case square1080   = "1080x1080"
    case square1350   = "1080x1350"

    var id: String { rawValue }

    var label: String {
        self == .source ? "Source" : rawValue
    }

    var aspectRatio: String? {
        switch self {
        case .source:       return nil
        case .hd1080:       return "16:9"
        case .hd720:        return "16:9"
        case .vertical1080: return "9:16"
        case .vertical720:  return "9:16"
        case .square1080:   return "1:1"
        case .square1350:   return "4:5"
        }
    }

    var ffmpegValue: String? {
        self == .source ? nil : rawValue
    }
}

enum FrameRate: String, CaseIterable, Identifiable, Codable {
    case source  = ""
    case fps2398 = "23.98"
    case fps24   = "24"
    case fps25   = "25"
    case fps2997 = "29.976"
    case fps30   = "30"

    var id: String { rawValue }

    var label: String {
        self == .source ? "Source" : rawValue
    }

    var ffmpegValue: String? {
        self == .source ? nil : rawValue
    }
}

enum AudioBitrate: String, CaseIterable, Identifiable, Codable {
    case k128 = "128"
    case k192 = "192"
    case k256 = "256"
    case k320 = "320"
    var id: String { rawValue }
    var label: String { rawValue + " kbps" }
    var ffmpegValue: String { rawValue + "k" }
}

enum SampleRate: String, CaseIterable, Identifiable, Codable {
    case hz44100 = "44100"
    case hz48000 = "48000"
    var id: String { rawValue }
    var label: String { rawValue + " Hz" }
}

enum AudioCodec: String, CaseIterable, Identifiable, Codable {
    case aac = "AAC"
    case pcm = "PCM"
    var id: String { rawValue }
    var ffmpegValue: String {
        switch self {
        case .aac: return "aac"
        case .pcm: return "pcm_s24le"
        }
    }
    // PCM doesn't use a bitrate
    var usesBitrate: Bool { self == .aac }
}

enum ProResCodec: String, CaseIterable, Identifiable, Codable {
    case hq422 = "422 HQ"
    case p4444 = "4444"
    var id: String { rawValue }
    var profileIndex: String {
        switch self {
        case .hq422: return "3"
        case .p4444: return "4"
        }
    }
    var pixFmt: String {
        switch self {
        case .hq422: return "yuv422p10le"
        case .p4444: return "yuva444p10le"
        }
    }
}

enum AudioSampleSize: String, CaseIterable, Identifiable, Codable {
    case bit16 = "16-bit"
    case bit24 = "24-bit"
    var id: String { rawValue }
    var pcmCodec: String {
        switch self {
        case .bit16: return "pcm_s16le"
        case .bit24: return "pcm_s24le"
        }
    }
}
