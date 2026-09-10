import Foundation

// Hand-built SOAP 1.1 client (Foundation has no SOAP support, and this stays
// dependency-free to match the rest of the app) for VidChecker Server's
// PublicService API — confirmed directly against the studio's own
// PublicService.wsdl documentation. Deliberately only calls PublicService,
// never PrivateService, per VidChecker's own guidance (private operations
// can change between releases without notice).
//
// Responses are parsed with Foundation's built-in XMLDocument + XPath rather
// than a hand-rolled parser — `local-name()` in every query sidesteps
// whatever namespace prefix WCF assigns to elements, so exact prefix
// matching is never a concern.
struct VidCheckerAPIClient {
    static let shared = VidCheckerAPIClient()

    // Fixed studio server address — VidChecker Server is a single shared
    // on-prem instance, not a per-user account like Frame.io.
    private let endpoint = URL(string: "http://10.3.33.238:51060/11/PublicService.svc")!
    private let soapNamespace = "http://www.vidcheck.com/services"

    // MARK: - Templates

    func listTemplates(completion: @escaping (Result<[VidCheckerTemplate], Error>) -> Void) {
        let body = "<ListTemplates xmlns=\"\(soapNamespace)\"/>"
        request(action: "ListTemplates", body: body) { result in
            completion(result.map { doc in
                let refs = (try? doc.nodes(forXPath: "//*[local-name()='TemplateRef']")) ?? []
                return refs.compactMap { node -> VidCheckerTemplate? in
                    guard let element = node as? XMLElement,
                          let idString = Self.childText(of: element, named: "Id"),
                          let id = Int(idString),
                          let name = Self.childText(of: element, named: "Name") else { return nil }
                    return VidCheckerTemplate(id: id, name: name)
                }
            })
        }
    }

    // MARK: - Task submission

    // `filename` must already be in the form VidChecker's own server can
    // read (a UNC path on its network, not the caller's local mount point).
    func newTask(filename: String, templateId: Int, completion: @escaping (Result<Int, Error>) -> Void) {
        let body = """
        <NewTask xmlns="\(soapNamespace)">
        <Filename>\(Self.xmlEscape(filename))</Filename>
        <TemplateId>\(templateId)</TemplateId>
        </NewTask>
        """
        request(action: "NewTask", body: body) { result in
            completion(result.flatMap { doc in
                guard let value = Self.firstText(in: doc, named: "NewTaskResult"), let id = Int(value) else {
                    return .failure(VidCheckerError.decoding("Missing NewTaskResult"))
                }
                return .success(id)
            })
        }
    }

    // MARK: - Task polling

    func getTask(id: Int, completion: @escaping (Result<VidCheckerTask, Error>) -> Void) {
        let body = """
        <GetTask xmlns="\(soapNamespace)">
        <id>\(id)</id>
        </GetTask>
        """
        request(action: "GetTask", body: body) { result in
            completion(result.flatMap { doc in
                guard let taskNodes = try? doc.nodes(forXPath: "//*[local-name()='GetTaskResult']"),
                      let taskElement = taskNodes.first as? XMLElement else {
                    return .failure(VidCheckerError.decoding("Missing GetTaskResult"))
                }
                let status = Self.childText(of: taskElement, named: "Status").flatMap(VidCheckerTaskStatus.init(rawValue:))
                let checkResult = Self.childText(of: taskElement, named: "CheckResult").flatMap(VidCheckerCheckResult.init(rawValue:))
                let percent = Self.childText(of: taskElement, named: "PercentComplete").flatMap(Int.init) ?? 0
                return .success(VidCheckerTask(status: status, checkResult: checkResult, percentComplete: percent))
            })
        }
    }

    // MARK: - Alerts (QC findings)

    func getAlerts(taskId: Int, completion: @escaping (Result<[VidCheckerAlert], Error>) -> Void) {
        let body = """
        <GetAlerts xmlns="\(soapNamespace)">
        <taskId>\(taskId)</taskId>
        </GetAlerts>
        """
        request(action: "GetAlerts", body: body) { result in
            completion(result.map { doc in
                let nodes = (try? doc.nodes(forXPath: "//*[local-name()='TaskAlert']")) ?? []
                return nodes.compactMap { node -> VidCheckerAlert? in
                    guard let element = node as? XMLElement,
                          let idString = Self.childText(of: element, named: "Id"),
                          let id = Int(idString) else { return nil }
                    let type = Self.childText(of: element, named: "Type")
                    let level = Self.childText(of: element, named: "Level").flatMap(VidCheckerAlertLevel.init(rawValue:))
                    let detail = Self.childText(of: element, named: "Detail")
                    var beginSeconds: Double?
                    if let beginTimeNodes = try? element.nodes(forXPath: "*[local-name()='BeginTime']"),
                       let beginTimeElement = beginTimeNodes.first as? XMLElement {
                        beginSeconds = Self.childText(of: beginTimeElement, named: "TotalSeconds").flatMap(Double.init)
                    }
                    return VidCheckerAlert(id: id, type: type, level: level, detail: detail, beginSeconds: beginSeconds)
                }
            })
        }
    }

    // MARK: - Core SOAP plumbing

    private func request(action: String, body: String, completion: @escaping (Result<XMLDocument, Error>) -> Void) {
        let envelope = """
        <?xml version="1.0" encoding="utf-8"?>
        <soap:Envelope xmlns:soap="http://schemas.xmlsoap.org/soap/envelope/">
        <soap:Body>
        \(body)
        </soap:Body>
        </soap:Envelope>
        """

        var urlRequest = URLRequest(url: endpoint)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("text/xml; charset=utf-8", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue("\(soapNamespace)/IPublicService/\(action)", forHTTPHeaderField: "SOAPAction")
        urlRequest.httpBody = Data(envelope.utf8)

        URLSession.shared.dataTask(with: urlRequest) { data, response, error in
            if let error {
                completion(.failure(error))
                return
            }
            guard let data else {
                completion(.failure(VidCheckerError.decoding("Empty response")))
                return
            }
            // A SOAP Fault typically comes back as HTTP 500 with fault XML in
            // the body — surface whatever text is there either way, rather
            // than only on a 2xx status.
            guard let doc = try? XMLDocument(data: data, options: []) else {
                let body = String(data: data, encoding: .utf8) ?? ""
                let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
                completion(.failure(VidCheckerError.httpError(statusCode, body)))
                return
            }
            if let faultString = Self.firstText(in: doc, named: "faultstring") ?? Self.firstText(in: doc, named: "Reason") {
                let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
                completion(.failure(VidCheckerError.httpError(statusCode, faultString)))
                return
            }
            completion(.success(doc))
        }.resume()
    }

    // MARK: - XML helpers

    // Finds the first element ANYWHERE in the document with this local name
    // (namespace-agnostic) and returns its text content.
    private static func firstText(in doc: XMLDocument, named name: String) -> String? {
        let nodes = try? doc.nodes(forXPath: "//*[local-name()='\(name)']")
        return nodes?.first?.stringValue
    }

    // Direct-child-only lookup, scoped to `element` — used for reading a
    // specific record's own fields (e.g. one TemplateRef's Id/Name) without
    // picking up a same-named field belonging to a different element.
    private static func childText(of element: XMLElement, named name: String) -> String? {
        let nodes = try? element.nodes(forXPath: "*[local-name()='\(name)']")
        return nodes?.first?.stringValue
    }

    private static func xmlEscape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }
}
