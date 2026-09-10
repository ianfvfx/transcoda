import Foundation

struct VidCheckerTemplate: Identifiable, Equatable {
    let id: Int
    let name: String
}

// Matches the TaskStatus enum restriction in VidChecker's PublicService WSDL
// exactly: { Waiting, Processing, Complete, PostProcessing, MovingFiles } —
// note there is no "Error" value here despite VidChecker's own sample-client
// docs polling for one; a genuine failure surfaces via CheckResult instead
// (see VidCheckerCheckResult) or as a SOAP-level fault/HTTP error.
enum VidCheckerTaskStatus: String {
    case waiting = "Waiting"
    case processing = "Processing"
    case complete = "Complete"
    case postProcessing = "PostProcessing"
    case movingFiles = "MovingFiles"
}

// Matches the TaskCheckResult enum restriction exactly.
enum VidCheckerCheckResult: String {
    case failed = "Failed"
    case passed = "Passed"
    case warning = "Warning"
    case reject = "Reject"
}

struct VidCheckerTask {
    let status: VidCheckerTaskStatus?
    let checkResult: VidCheckerCheckResult?
    let percentComplete: Int
}

// Matches the AlertLevel enum restriction exactly.
enum VidCheckerAlertLevel: String {
    case info = "AlInfo"
    case warning = "AlWarning"
    case reject = "AlReject"
    case fatal = "AlFatal"
}

struct VidCheckerAlert: Identifiable {
    let id: Int
    let type: String?
    let level: VidCheckerAlertLevel?
    let detail: String?
    let beginSeconds: Double?
}

enum VidCheckerError: LocalizedError {
    case httpError(Int, String)
    case decoding(String)

    var errorDescription: String? {
        switch self {
        case .httpError(let code, let body):
            return "Vidchecker returned an error (\(code)): \(body)"
        case .decoding(let message):
            return "Couldn't understand Vidchecker's response: \(message)"
        }
    }
}
