import Foundation

// Bumped by 1 (the `build` number) with every change pushed to git, tagged
// with the matching version string (e.g. "v1.0001") so any version can be
// rolled back to easily.
enum AppVersion {
    static let major = 1
    static let build = 1

    static var current: String { "\(major).\(String(format: "%04d", build))" }
}
