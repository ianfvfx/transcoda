import Foundation

// Fixed, hardcoded UUIDs for built-in presets so identity stays stable across
// app launches and versions (important since the working-copy/reselect-to-reset
// flow keys off preset id).
enum BuiltInPresets {

    static let mp4 = Preset(
        id: UUID(uuidString: "8F2C1A00-0001-4000-8000-000000000001")!,
        name: "MP4",
        origin: .builtIn,
        kind: .structured(.defaultH264MP4()),
        outputExtension: "mp4",
        outputSuffix: ""
    )

    static let proRes = Preset(
        id: UUID(uuidString: "8F2C1A00-0001-4000-8000-000000000002")!,
        name: "ProRes",
        origin: .builtIn,
        kind: .structured(.defaultProRes()),
        outputExtension: "mov",
        outputSuffix: ""
    )

    static let clearcastMP4 = Preset(
        id: UUID(uuidString: "8F2C1A00-0001-4000-8000-000000000003")!,
        name: "Clearcast MP4",
        origin: .builtIn,
        kind: .structured(StructuredSettings(
            codecFamily: .h264Mp4,
            resolution: .source,
            framerate: .source,
            scan: .autoDetect,
            bitrateMbps: StructuredSettings.defaultH264BitrateMbps,
            audioCodec: .aac,
            audioBitrate: .k192,
            proResCodec: .hq422,
            audioSampleSize: .bit24,
            audioSampleRate: .hz48000
        )),
        outputExtension: "mp4",
        outputSuffix: "_CC"
    )

    static let clearcastProRes = Preset(
        id: UUID(uuidString: "8F2C1A00-0001-4000-8000-000000000004")!,
        name: "Clearcast ProRes",
        origin: .builtIn,
        kind: .advanced(rawTemplate: """
        -y -i {input} -vf setfield=tff -c:v prores_ks -profile:v 3 -pix_fmt yuv422p10le \
        -r 25 -s 1920x1080 -aspect 16:9 -flags +ildct+ilme -b:v 114M \
        -color_primaries bt709 -color_trc bt709 -colorspace bt709 \
        -c:a pcm_s16le -ar 48000 -ac 2 -f mov -progress pipe:1 {output}
        """),
        outputExtension: "mov",
        outputSuffix: "_CC"
    )

    static let extremeReach = Preset(
        id: UUID(uuidString: "8F2C1A00-0001-4000-8000-000000000005")!,
        name: "Extreme Reach UK",
        origin: .builtIn,
        kind: .advanced(rawTemplate: """
        -y -i {input} -vf setfield=tff -c:v prores_ks -profile:v 3 -pix_fmt yuv422p10le \
        -r 25 -s 1920x1080 -aspect 16:9 -flags +ildct+ilme \
        -color_primaries bt709 -color_trc bt709 -colorspace bt709 \
        -c:a pcm_s24le -ar 48000 -ac 2 -f mov -progress pipe:1 {output}
        """),
        outputExtension: "mov",
        outputSuffix: "_XR"
    )

    static let peach = Preset(
        id: UUID(uuidString: "8F2C1A00-0001-4000-8000-000000000006")!,
        name: "Peach",
        origin: .builtIn,
        kind: .advanced(rawTemplate: """
        -y -i {input} -filter_complex [0:a]channelsplit=channel_layout=stereo[left][right] \
        -map 0:v:0 -map [left] -c:a:0 pcm_s24le -ac:0 1 -map [right] -c:a:1 pcm_s24le -ac:1 1 \
        -vf yadif=mode=1:parity=1,setfield=tff,format=yuv422p -c:v mpeg2video -pix_fmt yuv422p \
        -b:v 50000k -minrate 50000k -maxrate 50000k -bufsize 36408333 \
        -r 25 -s 1920x1080 -aspect 16:9 -flags +ildct+ilme -dc 10 -sc_threshold 1000000000 \
        -g 12 -bf 2 -f mxf -progress pipe:1 {output}
        """),
        outputExtension: "mxf",
        outputSuffix: "_PEACH"
    )

    static let all: [Preset] = [mp4, proRes, clearcastMP4, clearcastProRes, extremeReach, peach]
}
