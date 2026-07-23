import SwiftUI

struct JobRowView: View {
    @ObservedObject var job: EncodingJob
    var estimatedOutputBytes: Int64? = nil
    var onRemove: (() -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                statusIcon
                    .frame(width: 16)

                VStack(alignment: .leading, spacing: 2) {
                    Text(job.displayName)
                        .font(.system(.body, design: .monospaced))
                        .lineLimit(1)
                        .truncationMode(.middle)

                    // Only show output filename once options have been stamped
                    if job.status != .waiting {
                        Text(job.outputURL.lastPathComponent)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }

                Spacer()

                VStack(alignment: .trailing, spacing: 2) {
                    Text(job.statusLabel)
                        .font(.caption)
                        .foregroundStyle(statusColor)

                    if job.status == .encoding, job.fps > 0 {
                        Text(String(format: "%.1f fps", job.fps))
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }

                    if job.status == .waiting, let estimatedOutputBytes {
                        Text("~\(sizeFormatter.string(fromByteCount: estimatedOutputBytes)) est.")
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                }

                if let onRemove {
                    Button(action: onRemove) {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .disabled(job.status == .encoding)
                    .opacity(job.status == .encoding ? 0.3 : 1)
                    .help("Remove from queue")
                }
            }

            if job.status == .encoding || job.status == .complete {
                ProgressView(value: job.progress)
                    .progressViewStyle(.linear)
                    .tint(progressTint)
                    .animation(.easeInOut(duration: 0.3), value: job.progress)
            }
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 10)
        .background(rowBackground)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    // MARK: - Helpers

    private var sizeFormatter: ByteCountFormatter {
        let f = ByteCountFormatter()
        f.countStyle = .file
        return f
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch job.status {
        case .waiting:
            Image(systemName: "clock")
                .foregroundStyle(.secondary)
        case .encoding:
            ProgressView()
                .scaleEffect(0.6)
                .frame(width: 16, height: 16)
        case .complete:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .failed:
            Image(systemName: "xmark.circle.fill")
                .foregroundStyle(.red)
        }
    }

    private var statusColor: Color {
        switch job.status {
        case .waiting:  return .secondary
        case .encoding: return .accentColor
        case .complete: return .green
        case .failed:   return .red
        }
    }

    private var progressTint: Color {
        if case .complete = job.status { return .green }
        return .accentColor
    }

    private var rowBackground: Color {
        switch job.status {
        case .complete: return Color.green.opacity(0.08)
        case .failed:   return Color.red.opacity(0.08)
        default:        return Color(NSColor.controlBackgroundColor)
        }
    }
}
