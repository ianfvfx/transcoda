import Foundation

// MARK: - Envelope wrappers

// Frame.io V4 wraps every response body in {"data": ...}.
struct FrameIODataEnvelope<T: Decodable>: Decodable {
    let data: T
}

struct FrameIOListEnvelope<T: Decodable>: Decodable {
    let data: [T]
    let links: FrameIOLinks?
}

// `next` is the request path for the following page (cursor already
// embedded via the `after` query param), or nil once there are no more
// pages. List endpoints default to 50 items per page, so this is required
// for any account with more than 50 accounts/workspaces/projects.
struct FrameIOLinks: Decodable {
    let next: String?
}

// MARK: - Hierarchy

struct FrameIOAccount: Decodable {
    let id: String
    let name: String?
}

struct FrameIOWorkspace: Decodable {
    let id: String
    let name: String?
}

struct FrameIOProject: Decodable {
    let id: String
    let name: String
    let rootFolderID: String

    enum CodingKeys: String, CodingKey {
        case id, name
        case rootFolderID = "root_folder_id"
    }
}

// Flattened, UI-facing option — a project plus the account it lives under,
// since folder/share endpoints are account-scoped and the picker only ever
// shows the project name.
struct FrameIOProjectOption: Identifiable {
    let accountID: String
    let project: FrameIOProject
    var id: String { project.id }
}

// MARK: - Files & folders

struct FrameIOFolder: Decodable {
    let id: String
    let name: String
}

struct FrameIOUploadURLChunk: Decodable {
    let size: Int64
    let url: URL
}

struct FrameIOAssetCreateResponse: Decodable {
    let id: String
    let status: String
    let uploadURLs: [FrameIOUploadURLChunk]?

    enum CodingKeys: String, CodingKey {
        case id, status
        case uploadURLs = "upload_urls"
    }
}

// MARK: - Sharing

struct FrameIOShare: Decodable {
    let id: String
    let shortURL: String

    enum CodingKeys: String, CodingKey {
        case id
        case shortURL = "short_url"
    }
}

// MARK: - Errors

enum FrameIOError: LocalizedError {
    case notAuthenticated
    case httpError(Int, String)
    case decoding(Error)
    case cancelled
    case noProjectsFound

    var errorDescription: String? {
        switch self {
        case .notAuthenticated:
            return "Not signed in to Frame.io."
        case .httpError(let code, let body):
            return "Frame.io returned an error (\(code)): \(body)"
        case .decoding(let error):
            return "Couldn't understand Frame.io's response: \(error.localizedDescription)"
        case .cancelled:
            return "Sign-in was cancelled."
        case .noProjectsFound:
            return "No Frame.io projects found for this account."
        }
    }
}
