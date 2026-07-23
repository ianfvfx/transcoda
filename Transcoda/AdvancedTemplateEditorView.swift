import SwiftUI

/// Editor for an "advanced" preset's raw ffmpeg argument template.
/// `{input}`/`{output}` are substituted with the real file paths at encode time.
struct AdvancedTemplateEditorView: View {
    @Binding var rawTemplate: String

    private var missingOutputToken: Bool {
        !rawTemplate.contains("{output}")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "terminal")
                    .foregroundStyle(.secondary)
                Text("Raw ffmpeg arguments — use ")
                    + Text("{input}").font(.system(.caption, design: .monospaced)).bold()
                    + Text(" and ")
                    + Text("{output}").font(.system(.caption, design: .monospaced)).bold()
                    + Text(" as placeholders.")
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            TextEditor(text: $rawTemplate)
                .font(.system(.caption, design: .monospaced))
                .frame(minHeight: 90, maxHeight: 140)
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color(NSColor.separatorColor), lineWidth: 1)
                )

            if missingOutputToken {
                Label("Template has no {output} placeholder — the encode will run without an output path.", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
    }
}
