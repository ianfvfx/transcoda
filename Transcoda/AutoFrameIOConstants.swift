import Foundation

// Fixed configuration for the AutoFrameIO utility — ported from the
// standalone autoframeio Python tool (/Users/ian.fallon/Documents/Claude/autoframeio),
// specifically autoframeio/constants.py. Kept as hardcoded constants here,
// same as that tool and matching Transcoda's own style of fixed per-preset
// ffmpeg specs, rather than exposed as editable settings.
enum AutoFrameIOConstants {
    // MARK: - Output

    static let outputRoot: URL = {
        FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first!
            .appendingPathComponent("AutoFrameIO")
    }()

    // MARK: - Encoding

    // The house MP4 mezzanine spec — every video AutoFrameIO encodes uses
    // exactly this, never a user-chosen preset.
    static func ffmpegArguments(input: String, output: String) -> [String] {
        [
            "-y", "-i", input,
            "-c:v", "libx264", "-preset", "veryfast", "-profile:v", "high", "-level:v", "4.1",
            "-b:v", "18M", "-maxrate", "18M", "-bufsize", "18M",
            "-x264-params", "nal-hrd=cbr:force-cfr=1",
            "-g", "25", "-keyint_min", "30",
            "-pix_fmt", "yuv420p",
            "-color_primaries", "bt709", "-color_trc", "bt709", "-colorspace", "bt709",
            "-movflags", "+faststart",
            "-c:a", "aac", "-b:a", "192k", "-ac", "2", "-ar", "48000",
            output,
        ]
    }

    // MARK: - File types

    static let videoExtensions: Set<String> = ["mov", "mp4", "mxf", "avi", "mkv", "m4v", "wmv"]
    static let imageExtensions: Set<String> = ["jpg", "jpeg", "png", "tif", "tiff"]

    // MARK: - Watching

    // Deliberately polling rather than FSEvents — watch folders live on
    // network storage (/Volumes/jobs/...), where FSEvents is unreliable
    // regardless of machine, matching the standalone tool's own reasoning
    // for using watchdog's PollingObserver instead of its native backend.
    static let pollIntervalSeconds: TimeInterval = 30
    // How long to wait after a file is first seen before checking whether
    // it has finished writing.
    static let ingestDelaySeconds: TimeInterval = 5
    static let stabilityChecks = 6
    static let stabilityIntervalSeconds: TimeInterval = 5

    // MARK: - Email

    // Sent via Microsoft 365 "Direct Send" — an unauthenticated connection
    // straight to Exchange Online Protection, accepted purely because the
    // sending machine's IP falls within blackkitestudios.com's SPF record.
    // No credentials. Only works from a network whose egress IP is
    // SPF-authorized (the office network) — see
    // autoframeio/README.md in the standalone tool this was ported from.
    static let smtpHost = "blackkitestudios-com.mail.protection.outlook.com"
    static let smtpPort: UInt16 = 25
    static let fromAddress = "techops@blackkitestudios.com"
}
