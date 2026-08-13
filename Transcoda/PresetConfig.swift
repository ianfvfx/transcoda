import Foundation

let ffmpegPath  = "/Applications/ffmpeg"
let ffprobePath = "/Applications/ffprobe"

enum PresetConfig {

    // MARK: - ffprobe helper

    private static func runProbe(_ args: [String]) -> String? {
        let probe = Process()
        probe.executableURL = URL(fileURLWithPath: ffprobePath)
        probe.arguments = args
        let pipe = Pipe()
        probe.standardOutput = pipe
        probe.standardError  = Pipe()
        try? probe.run()
        probe.waitUntilExit()
        let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (out?.isEmpty == false) ? out : nil
    }

    // MARK: - Field-order detection
    static func isProgressive(_ inputURL: URL) -> Bool {
        runProbe([
            "-v", "error", "-select_streams", "v:0",
            "-show_entries", "stream=field_order",
            "-of", "default=nokey=1:noprint_wrappers=1",
            inputURL.path
        ]) == "progressive"
    }

    // MARK: - Duration detection
    static func duration(_ inputURL: URL) -> Double {
        let out = runProbe([
            "-v", "error", "-show_entries", "format=duration",
            "-of", "default=nokey=1:noprint_wrappers=1",
            inputURL.path
        ])
        return out.flatMap(Double.init) ?? 0
    }

    // MARK: - Trim-adjusted duration
    //
    // When a structured preset has a valid Trim Start value, the real encoded
    // output is that many seconds shorter than the source (an -ss seek before
    // -i). Progress reporting needs the trimmed duration, not the source
    // duration, or it never reaches 100%.
    static func effectiveDuration(for preset: Preset, sourceDuration: Double) -> Double {
        guard let trim = trimStartValue(for: preset) else { return sourceDuration }
        return max(sourceDuration - trim, 0.1)
    }

    // Parses a structured preset's trimStartSeconds field — nil if blank, not a
    // number, or not positive (no trim).
    private static func trimStartValue(for preset: Preset) -> Double? {
        guard case .structured(let settings) = preset.kind else { return nil }
        let trimmed = settings.trimStartSeconds.trimmingCharacters(in: .whitespaces)
        guard let value = Double(trimmed), value > 0 else { return nil }
        return value
    }

    // MARK: - Timecode shift for Trim Start
    //
    // Without this, ffmpeg's mov/mxf muxers carry the SOURCE's original starting
    // timecode straight through unchanged even when -ss trims seconds off the
    // front — so a file starting at 09:59:50:00, trimmed by 10s, would still
    // read 09:59:50:00 instead of the correct 10:00:00:00. This reads the
    // source's embedded start timecode and frame rate via ffprobe and shifts it
    // forward by the trimmed duration.
    //
    // Only handles non-drop-frame timecode (":" frame separator). Drop-frame
    // (";" separator — an NTSC-only convention) is left unshifted rather than
    // risk an incorrect drop-frame calculation; every built-in preset here is a
    // UK/PAL broadcast delivery spec, where drop-frame essentially doesn't occur.
    private static func shiftedTimecode(inputURL: URL, trimSeconds: Double, framerateOverride: String?) -> String? {
        guard let sourceTC = probeTimecode(inputURL), !sourceTC.contains(";") else { return nil }
        let parts = sourceTC.split(separator: ":").compactMap { Int($0) }
        guard parts.count == 4 else { return nil }

        let fps: Double
        if let framerateOverride, let v = Double(framerateOverride) {
            fps = v
        } else if let probed = probeFrameRate(inputURL) {
            fps = probed
        } else {
            return nil
        }
        let frRound = Int(fps.rounded())
        guard frRound > 0 else { return nil }

        let (h, m, s, f) = (parts[0], parts[1], parts[2], parts[3])
        let startFrames = ((h * 3600 + m * 60 + s) * frRound) + f
        let shiftFrames = Int((trimSeconds * Double(frRound)).rounded())
        let totalFrames = startFrames + shiftFrames

        let newF = totalFrames % frRound
        let totalSeconds = totalFrames / frRound
        let newS = totalSeconds % 60
        let newM = (totalSeconds / 60) % 60
        let newH = (totalSeconds / 3600) % 24

        return String(format: "%02d:%02d:%02d:%02d", newH, newM, newS, newF)
    }

    private static func probeTimecode(_ inputURL: URL) -> String? {
        if let tc = runProbe([
            "-v", "error", "-select_streams", "v:0",
            "-show_entries", "stream_tags=timecode",
            "-of", "default=nokey=1:noprint_wrappers=1",
            inputURL.path
        ]) { return tc }

        return runProbe([
            "-v", "error", "-show_entries", "format_tags=timecode",
            "-of", "default=nokey=1:noprint_wrappers=1",
            inputURL.path
        ])
    }

    private static func probeFrameRate(_ inputURL: URL) -> Double? {
        guard let raw = runProbe([
            "-v", "error", "-select_streams", "v:0",
            "-show_entries", "stream=r_frame_rate",
            "-of", "default=nokey=1:noprint_wrappers=1",
            inputURL.path
        ]) else { return nil }

        let comps = raw.split(separator: "/").compactMap { Double($0) }
        if comps.count == 2, comps[1] != 0 { return comps[0] / comps[1] }
        if comps.count == 1 { return comps[0] }
        return nil
    }

    // Blank Bitrate field falls back to the same default shown as its
    // placeholder (StructuredSettings.defaultH264BitrateMbps) — this is a real
    // fallback used in the actual ffmpeg command, not just cosmetic hint text.
    private static func effectiveBitrateMbps(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? StructuredSettings.defaultH264BitrateMbps : trimmed
    }

    // nil unless both customWidth/customHeight are valid positive integers —
    // evenness is a UI-level validation concern (ContentView.optionsValid),
    // not enforced here, matching how bitrate/max-size validation is split
    // between mechanical arg-building (this file) and gating (ContentView).
    private static func customResolutionValue(_ settings: StructuredSettings) -> String? {
        let w = settings.customWidth.trimmingCharacters(in: .whitespaces)
        let h = settings.customHeight.trimmingCharacters(in: .whitespaces)
        guard let wi = Int(w), let hi = Int(h), wi > 0, hi > 0 else { return nil }
        return "\(wi)x\(hi)"
    }

    // nil unless customFramerate is a valid positive number. Unlike width/
    // height, decimals are meaningful here (23.976, 29.97) so the raw typed
    // string is passed straight through rather than reformatted.
    private static func customFramerateValue(_ settings: StructuredSettings) -> String? {
        let fr = settings.customFramerate.trimmingCharacters(in: .whitespaces)
        guard let v = Double(fr), v > 0 else { return nil }
        return fr
    }

    // Shared by estimatedOutputBytes and calculatedBitrateMbps so the audio
    // portion of the size budget is computed identically in both directions.
    private static func audioBitsPerSecond(for settings: StructuredSettings) -> Double {
        switch settings.audioCodec {
        case .aac:
            return (Double(settings.audioBitrate.rawValue) ?? 0) * 1000
        case .pcm:
            // Matches AudioCodec.pcm's hardcoded pcm_s24le, stereo.
            let sampleRate = Double(settings.audioSampleRate.rawValue) ?? 48000
            return sampleRate * 24 * 2
        }
    }

    // MARK: - Estimated output size
    //
    // Only meaningful for the H.264/MP4 structured family, since it's the one
    // preset shape using a constant target bitrate (-b:v/-maxrate/-bufsize all
    // equal) rather than a quality-based codec — size ≈ (video + audio bitrate)
    // × duration is a solid approximation there. Returns nil for anything else
    // (ProRes, advanced presets) where bitrate isn't a fixed target.
    static func estimatedOutputBytes(preset: Preset, sourceDurationSeconds: Double) -> Int64? {
        guard case .structured(let settings) = preset.kind, settings.codecFamily == .h264Mp4 else { return nil }
        guard let videoMbps = Double(effectiveBitrateMbps(settings.bitrateMbps)), videoMbps > 0 else { return nil }
        guard sourceDurationSeconds > 0 else { return nil }

        let duration = effectiveDuration(for: preset, sourceDuration: sourceDurationSeconds)
        let videoBitsPerSecond = videoMbps * 1_000_000
        let totalBitsPerSecond = videoBitsPerSecond + audioBitsPerSecond(for: settings)
        return Int64((totalBitsPerSecond * duration) / 8.0)
    }

    // MARK: - Max File Size → calculated bitrate
    //
    // The reverse of estimatedOutputBytes: given a target file size, solve for
    // the video bitrate that would produce it. A 2% margin keeps real output
    // safely under the target rather than exactly at it, absorbing container
    // overhead and any residual encoder rounding. `mbps` is floored to 2
    // decimal places — fine enough to distinguish values below 0.1 Mbps, not
    // just 1.0/0.1-style round numbers. No enforced floor beyond
    // `absoluteMinimumMbps` (a purely technical safety net so -b:v is never
    // zero/negative, which ffmpeg would reject outright) — a target size too
    // small for the file's length is still honored as calculated;
    // `belowRecommendedMinimum` just flags it so the UI can warn that quality
    // may suffer, rather than silently clamping.
    struct MaxSizeBitrateResult {
        let mbps: Double
        let belowRecommendedMinimum: Bool
    }

    private static let maxSizeMarginFactor = 0.98
    static let recommendedMinimumMbps = 1.0
    private static let absoluteMinimumMbps = 0.01

    static func calculatedBitrateMbps(settings: StructuredSettings, effectiveDurationSeconds: Double) -> MaxSizeBitrateResult? {
        let trimmed = settings.maxFileSizeMB.trimmingCharacters(in: .whitespaces)
        guard let maxSizeMB = Double(trimmed), maxSizeMB > 0, effectiveDurationSeconds > 0 else { return nil }

        let targetBytes = maxSizeMB * 1_000_000 * maxSizeMarginFactor
        let totalBitsPerSecond = (targetBytes * 8) / effectiveDurationSeconds
        let videoBitsPerSecond = totalBitsPerSecond - audioBitsPerSecond(for: settings)
        let rawMbps = videoBitsPerSecond / 1_000_000
        let flooredMbps = (rawMbps * 100).rounded(.down) / 100

        let mbps = max(flooredMbps, absoluteMinimumMbps)
        return MaxSizeBitrateResult(mbps: mbps, belowRecommendedMinimum: mbps < recommendedMinimumMbps)
    }

    // Substitutes a per-file calculated bitrate into a copy of `preset` when
    // Max File Size is active, using `sourceDurationSeconds` (that specific
    // file's own duration) — this is what makes files of different lengths in
    // the same queue each get an independently correct bitrate. Returns
    // `preset` unchanged for anything Max File Size doesn't apply to (ProRes,
    // advanced presets, blank Max Size field, or an unknown duration).
    static func effectivePreset(for preset: Preset, sourceDurationSeconds: Double?) -> Preset {
        guard case .structured(var settings) = preset.kind, settings.codecFamily == .h264Mp4 else { return preset }
        guard !settings.maxFileSizeMB.trimmingCharacters(in: .whitespaces).isEmpty else { return preset }
        guard let sourceDurationSeconds else { return preset }

        let effectiveDur = effectiveDuration(for: preset, sourceDuration: sourceDurationSeconds)
        guard let result = calculatedBitrateMbps(settings: settings, effectiveDurationSeconds: effectiveDur) else { return preset }

        settings.bitrateMbps = String(format: "%.2f", result.mbps)
        var newPreset = preset
        newPreset.kind = .structured(settings)
        return newPreset
    }

    // MARK: - Unified argument builder
    //
    // Single source of truth used both for the real ffmpeg invocation (EncodingQueue)
    // and the "FFmpeg Parameters" preview string (EncodeOptionsView) — avoids the two
    // near-duplicate switch statements the old arguments(for:)/previewArguments(...)
    // pair required.
    //
    // `inputURL` is the real source file, used only to resolve `.autoDetect` scan via
    // ffprobe. Pass nil for preview/display purposes (no real file to probe yet) —
    // `.autoDetect` is then treated as non-interlaced for display only.

    static func arguments(preset: Preset, inputURL: URL?, input: String, output: String) -> [String] {
        switch preset.kind {
        case .structured(let settings):
            return structuredArguments(settings: settings, inputURL: inputURL, input: input, output: output)
        case .advanced(let rawTemplate):
            return tokenize(rawTemplate, input: input, output: output)
        }
    }

    static func previewString(for preset: Preset) -> String {
        let args = arguments(preset: preset, inputURL: nil, input: "<input>", output: "<output>.\(preset.outputExtension)")
        return "ffmpeg " + args.joined(separator: " ")
    }

    private static func structuredArguments(settings: StructuredSettings, inputURL: URL?, input: String, output: String) -> [String] {
        let interlaced: Bool
        switch settings.scan {
        case .interlacedTFF: interlaced = true
        case .progressive:   interlaced = false
        case .autoDetect:    interlaced = inputURL.map { !isProgressive($0) } ?? false
        }

        var args = ["-y"]
        let trimmedStart = settings.trimStartSeconds.trimmingCharacters(in: .whitespaces)
        let trimValue = Double(trimmedStart)
        if let trimValue, trimValue > 0 { args += ["-ss", trimmedStart] }
        args += ["-i", input]
        var vfFilters = [String]()
        if interlaced { vfFilters.append("setfield=tff") }
        if let res = customResolutionValue(settings) ?? settings.resolution.ffmpegValue {
            vfFilters.append("scale=\(res)")
        }
        if !vfFilters.isEmpty { args += ["-vf", vfFilters.joined(separator: ",")] }
        if interlaced { args += ["-flags", "+ildct+ilme"] }
        let effectiveFramerate = customFramerateValue(settings) ?? settings.framerate.ffmpegValue
        if let fr = effectiveFramerate { args += ["-r", fr] }

        switch settings.codecFamily {
        case .h264Mp4:
            // Software libx264. -b:v/-maxrate/-bufsize alone only set a target
            // AVERAGE and a peak cap (VBV model) — x264's single-pass rate control
            // still lets the real output average drift below that target for
            // easy-to-compress content, since nothing forces it to pad up to the
            // requested rate. -x264-params nal-hrd=cbr is what actually asks x264
            // for HRD-compliant constant bitrate (padding the bitstream as needed
            // to hit the target exactly); force-cfr=1 keeps frame timing perfectly
            // regular, which true CBR's padding model assumes.
            // -preset veryfast trades some compression efficiency for much faster
            // encodes than the unset default ("medium").
            //
            // When Max File Size is active, the real per-file bitrate is only
            // known once a specific file's duration is available — EncodingQueue
            // substitutes the calculated value into bitrateMbps before stamping
            // a job (see PresetConfig.effectivePreset), so by the time a REAL
            // encode reaches here, bitrateMbps already holds that number. Only
            // the preview (inputURL == nil, no specific file in play) needs the
            // placeholder.
            let isMaxSizePreview = inputURL == nil && !settings.maxFileSizeMB.trimmingCharacters(in: .whitespaces).isEmpty
            let br = isMaxSizePreview ? "<calculated>" : effectiveBitrateMbps(settings.bitrateMbps) + "M"
            args += [
                "-c:v", "libx264", "-preset", "veryfast", "-profile:v", "high", "-level:v", "4.1",
                "-b:v", br, "-maxrate", br, "-bufsize", br,
                "-x264-params", "nal-hrd=cbr:force-cfr=1",
                "-g", "25", "-keyint_min", "30", "-pix_fmt", "yuv420p",
                "-color_primaries", "bt709", "-color_trc", "bt709", "-colorspace", "bt709",
                "-movflags", "+faststart",
                "-c:a", settings.audioCodec.ffmpegValue,
            ]
            if settings.audioCodec.usesBitrate { args += ["-b:a", settings.audioBitrate.ffmpegValue] }
            args += ["-ac", "2", "-ar", settings.audioSampleRate.rawValue]

        case .proRes:
            args += [
                "-c:v", "prores_ks",
                "-profile:v", settings.proResCodec.profileIndex,
                "-pix_fmt", settings.proResCodec.pixFmt,
                "-color_primaries", "bt709", "-color_trc", "bt709", "-colorspace", "bt709",
                "-c:a", settings.audioSampleSize.pcmCodec,
                "-ar", settings.audioSampleRate.rawValue, "-ac", "2",
                "-f", "mov"
            ]
        }

        if let trimValue, trimValue > 0, let inputURL {
            if let newTC = shiftedTimecode(inputURL: inputURL, trimSeconds: trimValue, framerateOverride: effectiveFramerate) {
                args += ["-timecode", newTC]
            }
        }

        args += ["-progress", "pipe:1", output]
        return args
    }

    // MARK: - Raw-template tokenizer (advanced presets)
    //
    // Simple whitespace split — safe for every current built-in template since none
    // of their fixed argument values contain an embedded space. A future advanced
    // preset that needs a space inside a single argument (e.g. a quoted filter
    // description) would need a smarter, quote-aware tokenizer than this.

    private static func tokenize(_ template: String, input: String, output: String) -> [String] {
        template
            .split(whereSeparator: { $0.isWhitespace })
            .map { token -> String in
                switch token {
                case "{input}":  return input
                case "{output}": return output
                default:         return String(token)
                }
            }
    }
}
