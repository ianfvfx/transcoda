import SwiftUI

struct JobRowView: View {
    @ObservedObject var job: EncodingJob
    var estimatedOutputBytes: Int64? = nil
    var onRemove: (() -> Void)? = nil

    @State private var showVidCheckerResults = false
    @State private var vidCheckerAlerts: [VidCheckerAlert] = []
    @State private var vidCheckerAlertsLoading = false
    @State private var vidCheckerAlertsError: String?

    // Only a finished Vidchecker job (pass or fail) has a task worth looking
    // up — nothing to show yet while waiting/checking.
    private var isVidCheckerResultsClickable: Bool {
        guard job.isVidCheckerJob, job.vidCheckerTaskId != nil else { return false }
        switch job.status {
        case .complete, .failed: return true
        case .waiting, .encoding: return false
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                statusIcon
                    .frame(width: 16)

                VStack(alignment: .leading, spacing: 2) {
                    Text(job.displayName)
                        .font(.body)
                        .lineLimit(1)
                        .truncationMode(.middle)

                    // Only show output filename once options have been stamped
                    // — never for VidChecker, which produces no output file.
                    if job.status != .waiting, !job.isVidCheckerJob {
                        Text(job.outputURL.lastPathComponent)
                            .font(.caption)
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

                    // Independent of job.status — an upload failure/progress
                    // is never allowed to mask a successful encode.
                    if job.uploadStatus != .none {
                        Text(uploadStatusLabel)
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundStyle(uploadStatusColor)
                            .help(uploadStatusHelp)
                    }
                }

                if isVidCheckerResultsClickable {
                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
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

            // Transcription has no stdout progress channel like ffmpeg's
            // -progress pipe:1, so job.progress just stays 0 until it jumps to
            // 1.0 on completion — a percentage bar stuck at 0% the whole time
            // is more confusing than no bar at all, so skip it while encoding.
            if job.status == .complete || (job.status == .encoding && !job.isTranscribeJob) {
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
        .contentShape(Rectangle())
        .onTapGesture {
            guard isVidCheckerResultsClickable else { return }
            presentVidCheckerResults()
        }
        .sheet(isPresented: $showVidCheckerResults) {
            vidCheckerResultsSheet
        }
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

    // MARK: - Frame.io upload status

    private var uploadStatusLabel: String {
        switch job.uploadStatus {
        case .none:                    return ""
        case .uploading(let progress): return "Uploading \(Int(progress * 100))%"
        case .uploaded:                return "Uploaded to Frame.io"
        case .failed:                  return "Frame.io upload failed"
        }
    }

    private var uploadStatusColor: Color {
        switch job.uploadStatus {
        case .none, .uploading: return .accentColor
        case .uploaded:         return .green
        case .failed:           return .red
        }
    }

    private var uploadStatusHelp: String {
        if case .failed(let message) = job.uploadStatus { return message }
        return uploadStatusLabel
    }

    // MARK: - Vidchecker results

    // VidChecker's own web UI has no bookmarkable/deep-linkable URL for a
    // specific task's results (confirmed by inspecting it directly — the
    // selected task lives only in in-memory click state, never the URL or
    // any client-side storage), so results are shown natively here instead,
    // fetched fresh via GetAlerts every time the row is opened.
    private func presentVidCheckerResults() {
        showVidCheckerResults = true
        guard let taskId = job.vidCheckerTaskId else { return }
        vidCheckerAlertsLoading = true
        vidCheckerAlertsError = nil
        VidCheckerAPIClient.shared.getAlerts(taskId: taskId) { result in
            DispatchQueue.main.async {
                vidCheckerAlertsLoading = false
                switch result {
                case .success(let alerts):
                    vidCheckerAlerts = alerts
                case .failure(let error):
                    vidCheckerAlertsError = error.localizedDescription
                }
            }
        }
    }

    private var vidCheckerResultsSheet: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(job.displayName)
                        .font(.headline)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if let result = job.vidCheckerCheckResult {
                        Text(result)
                            .font(.subheadline)
                            .foregroundStyle(statusColor)
                    }
                }
                Spacer()
                Button("Close") { showVidCheckerResults = false }
            }

            Divider()

            if vidCheckerAlertsLoading {
                ProgressView("Loading findings…")
                    .frame(maxWidth: .infinity, minHeight: 120)
            } else if let vidCheckerAlertsError {
                Text(vidCheckerAlertsError)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, minHeight: 120)
            } else if vidCheckerAlerts.isEmpty {
                Text("No findings reported.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 120)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(vidCheckerAlerts) { alert in
                            vidCheckerAlertRow(alert)
                        }
                    }
                }
            }
        }
        .padding(20)
        .frame(width: 480, height: 420)
    }

    private func vidCheckerAlertRow(_ alert: VidCheckerAlert) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: vidCheckerAlertIcon(alert.level))
                .foregroundStyle(vidCheckerAlertColor(alert.level))
                .frame(width: 16)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(alert.type ?? "Alert")
                        .font(.callout.weight(.semibold))
                    if let beginSeconds = alert.beginSeconds {
                        Text(vidCheckerTimecode(beginSeconds))
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                }
                if let detail = alert.detail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func vidCheckerAlertIcon(_ level: VidCheckerAlertLevel?) -> String {
        switch level {
        case .info:            return "info.circle"
        case .warning:         return "exclamationmark.triangle"
        case .reject, .fatal:  return "xmark.octagon"
        case .none:            return "questionmark.circle"
        }
    }

    private func vidCheckerAlertColor(_ level: VidCheckerAlertLevel?) -> Color {
        switch level {
        case .info:            return .secondary
        case .warning:         return .orange
        case .reject, .fatal:  return .red
        case .none:            return .secondary
        }
    }

    private func vidCheckerTimecode(_ seconds: Double) -> String {
        let total = Int(seconds)
        return String(format: "%02d:%02d:%02d", total / 3600, (total % 3600) / 60, total % 60)
    }
}
