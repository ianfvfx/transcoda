import Foundation

// Completion-closure REST client for Frame.io's V4 API — deliberately not
// async/await, matching the GCD-completion idiom used everywhere else in this
// codebase (EncodingQueue, EncodingJob). Every call transparently obtains a
// valid access token via FrameIOAuthManager first (refreshing/re-logging in
// as needed), so callers never touch tokens directly.
struct FrameIOAPIClient {
    static let shared = FrameIOAPIClient()

    // Confirmed against Frame.io's V4 API reference.
    private let baseURL = URL(string: "https://api.frame.io")!

    // MARK: - Projects

    // Chains accounts -> workspaces -> projects and flattens the result.
    // Tolerates individual accounts/workspaces that fail to list (skips them)
    // rather than failing the whole fetch over one inaccessible corner.
    func fetchAccessibleProjects(completion: @escaping (Result<[FrameIOProjectOption], Error>) -> Void) {
        request(method: "GET", path: "/v4/accounts", body: nil, decode: FrameIOListEnvelope<FrameIOAccount>.self) { result in
            switch result {
            case .failure(let error):
                completion(.failure(error))
            case .success(let envelope):
                self.sequentially(envelope.data, initial: [FrameIOProjectOption]()) { account, accumulated, next in
                    self.fetchWorkspaces(accountID: account.id) { workspacesResult in
                        guard case .success(let workspaces) = workspacesResult else {
                            next(accumulated)
                            return
                        }
                        self.sequentially(workspaces, initial: accumulated) { workspace, accumulated2, next2 in
                            self.fetchProjectsList(accountID: account.id, workspaceID: workspace.id) { projectsResult in
                                guard case .success(let projects) = projectsResult else {
                                    next2(accumulated2)
                                    return
                                }
                                let options = projects.map { FrameIOProjectOption(accountID: account.id, project: $0) }
                                next2(accumulated2 + options)
                            }
                        } completion: { updated in
                            next(updated)
                        }
                    }
                } completion: { allOptions in
                    completion(allOptions.isEmpty ? .failure(FrameIOError.noProjectsFound) : .success(allOptions))
                }
            }
        }
    }

    private func fetchWorkspaces(accountID: String, completion: @escaping (Result<[FrameIOWorkspace], Error>) -> Void) {
        request(method: "GET", path: "/v4/accounts/\(accountID)/workspaces", body: nil, decode: FrameIOListEnvelope<FrameIOWorkspace>.self) { result in
            completion(result.map { $0.data })
        }
    }

    private func fetchProjectsList(accountID: String, workspaceID: String, completion: @escaping (Result<[FrameIOProject], Error>) -> Void) {
        request(method: "GET", path: "/v4/accounts/\(accountID)/workspaces/\(workspaceID)/projects", body: nil, decode: FrameIOListEnvelope<FrameIOProject>.self) { result in
            completion(result.map { $0.data })
        }
    }

    // MARK: - Folders

    // NEEDS LIVE VERIFICATION: this path/body is the plausible symmetric
    // counterpart to the confirmed `GET .../folders/{folder_id}/children`
    // list endpoint, but wasn't directly confirmed against the API reference
    // (see the implementation plan's "needs live verification" section).
    func createFolder(accountID: String, parentFolderID: String, name: String, completion: @escaping (Result<FrameIOFolder, Error>) -> Void) {
        let path = "/v4/accounts/\(accountID)/folders/\(parentFolderID)/folders"
        let body: [String: Any] = ["data": ["name": name]]
        request(method: "POST", path: path, body: body, decode: FrameIODataEnvelope<FrameIOFolder>.self) { result in
            completion(result.map { $0.data })
        }
    }

    // MARK: - Upload

    // NEEDS LIVE VERIFICATION: path confirmed in spirit against Frame.io's
    // "Create file (local upload)" reference page, but the exact route
    // segment wasn't directly read from a rendered doc page — verify before
    // relying on it.
    func createFileUpload(accountID: String, parentFolderID: String, name: String, fileSize: Int64, completion: @escaping (Result<FrameIOAssetCreateResponse, Error>) -> Void) {
        let path = "/v4/accounts/\(accountID)/folders/\(parentFolderID)/files/local_upload"
        let body: [String: Any] = ["data": ["name": name, "file_size": fileSize]]
        request(method: "POST", path: path, body: body, decode: FrameIODataEnvelope<FrameIOAssetCreateResponse>.self) { result in
            completion(result.map { $0.data })
        }
    }

    // Uploads chunks strictly in array order (required — they dictate the
    // final concatenated file), one automatic retry per failed chunk before
    // giving up. `progress` is called back on the main thread.
    func uploadChunks(_ chunks: [FrameIOUploadURLChunk], fileURL: URL, contentType: String, progress: @escaping (Double) -> Void, completion: @escaping (Result<Void, Error>) -> Void) {
        guard let fileHandle = try? FileHandle(forReadingFrom: fileURL) else {
            completion(.failure(FrameIOError.httpError(-1, "Couldn't open \(fileURL.lastPathComponent) for reading")))
            return
        }

        let totalSize = max(chunks.reduce(Int64(0)) { $0 + $1.size }, 1)
        var uploadedSoFar: Int64 = 0

        func uploadChunk(at index: Int, isRetry: Bool) {
            guard index < chunks.count else {
                try? fileHandle.close()
                completion(.success(()))
                return
            }
            let chunk = chunks[index]
            let data = fileHandle.readData(ofLength: Int(chunk.size))

            var chunkRequest = URLRequest(url: chunk.url)
            chunkRequest.httpMethod = "PUT"
            chunkRequest.setValue("private", forHTTPHeaderField: "x-amz-acl")
            chunkRequest.setValue(contentType, forHTTPHeaderField: "Content-Type")
            chunkRequest.httpBody = data

            URLSession.shared.dataTask(with: chunkRequest) { _, response, error in
                let statusCode = (response as? HTTPURLResponse)?.statusCode
                let ok = statusCode.map { (200..<300).contains($0) } ?? false
                if ok {
                    uploadedSoFar += chunk.size
                    let fraction = Double(uploadedSoFar) / Double(totalSize)
                    DispatchQueue.main.async { progress(fraction) }
                    uploadChunk(at: index + 1, isRetry: false)
                } else if !isRetry {
                    uploadChunk(at: index, isRetry: true)
                } else {
                    try? fileHandle.close()
                    let message = error?.localizedDescription ?? "Upload chunk \(index + 1)/\(chunks.count) failed"
                    completion(.failure(FrameIOError.httpError(statusCode ?? -1, message)))
                }
            }.resume()
        }

        uploadChunk(at: 0, isRetry: false)
    }

    // MARK: - Sharing

    func createShare(accountID: String, projectID: String, name: String, assetIDs: [String], completion: @escaping (Result<FrameIOShare, Error>) -> Void) {
        let path = "/v4/accounts/\(accountID)/projects/\(projectID)/shares"
        let body: [String: Any] = [
            "data": [
                "type": "asset",
                "access": "public",
                "name": name,
                "asset_ids": assetIDs
            ]
        ]
        request(method: "POST", path: path, body: body, decode: FrameIODataEnvelope<FrameIOShare>.self) { result in
            completion(result.map { $0.data })
        }
    }

    // MARK: - Core request plumbing

    private func request<T: Decodable>(
        method: String,
        path: String,
        body: [String: Any]?,
        decode: T.Type,
        completion: @escaping (Result<T, Error>) -> Void
    ) {
        Task { @MainActor in
            FrameIOAuthManager.shared.validAccessToken { result in
                switch result {
                case .failure(let error):
                    completion(.failure(error))
                case .success(let token):
                    var urlRequest = URLRequest(url: self.baseURL.appendingPathComponent(path))
                    urlRequest.httpMethod = method
                    urlRequest.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
                    if let body {
                        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
                        urlRequest.httpBody = try? JSONSerialization.data(withJSONObject: body)
                    }
                    URLSession.shared.dataTask(with: urlRequest) { data, response, error in
                        if let error {
                            completion(.failure(error))
                            return
                        }
                        guard let http = response as? HTTPURLResponse, let data else {
                            completion(.failure(FrameIOError.httpError(-1, "No response")))
                            return
                        }
                        guard (200..<300).contains(http.statusCode) else {
                            completion(.failure(FrameIOError.httpError(http.statusCode, String(data: data, encoding: .utf8) ?? "")))
                            return
                        }
                        do {
                            completion(.success(try JSONDecoder().decode(T.self, from: data)))
                        } catch {
                            completion(.failure(FrameIOError.decoding(error)))
                        }
                    }.resume()
                }
            }
        }
    }

    // Walks `elements` one at a time, threading an accumulated `Result`
    // through each `step` so calls stay strictly sequential (kind to rate
    // limits, and lets each step tolerate individual failures by simply
    // passing the accumulator through unchanged).
    private func sequentially<Element, Accumulated>(
        _ elements: [Element],
        initial: Accumulated,
        step: @escaping (Element, Accumulated, @escaping (Accumulated) -> Void) -> Void,
        completion: @escaping (Accumulated) -> Void
    ) {
        var remaining = elements
        var accumulated = initial
        func next() {
            guard !remaining.isEmpty else {
                completion(accumulated)
                return
            }
            let element = remaining.removeFirst()
            step(element, accumulated) { updated in
                accumulated = updated
                next()
            }
        }
        next()
    }
}
