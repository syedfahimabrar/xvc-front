import Foundation

/// Client for the two endpoints in the README: `load-target` and `stream`.
public final class XVCClient: NSObject, URLSessionDelegate {
    private let host: String
    private let port: Int
    private let allowSelfSigned: Bool
    private let token: String

    private lazy var session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)

    public init(host: String, port: Int, allowSelfSigned: Bool, token: String = "") {
        self.host = host
        self.port = port
        self.allowSelfSigned = allowSelfSigned
        self.token = token
    }

    /// POST /api/meanvc/load-target, multipart with a single field named `wav`.
    /// Returns the target_id — an in-memory handle that does not survive a server restart.
    public func loadTarget(wavURL: URL) async throws -> (id: String, duration: Double) {
        let boundary = UUID().uuidString
        var body = Data()
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"wav\"; filename=\"target.wav\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: audio/wav\r\n\r\n".data(using: .utf8)!)
        body.append(try Data(contentsOf: wavURL))
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)

        var request = URLRequest(url: URL(string: "https://\(host):\(port)/api/meanvc/load-target")!)
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        if !token.isEmpty { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }

        let (data, response) = try await session.upload(for: request, from: body)
        guard let http = response as? HTTPURLResponse else { throw XVCError("no HTTP response") }
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        if let error = json["error"] as? String { throw XVCError("load-target: \(error)") }
        guard http.statusCode == 200, let id = json["target_id"] as? String else {
            throw XVCError("load-target failed (HTTP \(http.statusCode)): \(String(decoding: data, as: UTF8.self))")
        }
        return (id, json["duration_seconds"] as? Double ?? 0)
    }

    /// Opens the stream and waits for `{"status":"ready"}` before returning. Clients MUST
    /// NOT send audio before that frame arrives (the README).
    public func openStream(targetID: String, sourceRate: Int) async throws -> URLSessionWebSocketTask {
        var components = URLComponents()
        components.scheme = "wss"
        components.host = host
        components.port = port
        components.path = "/api/meanvc/stream"
        components.queryItems = [
            URLQueryItem(name: "target_id", value: targetID),
            URLQueryItem(name: "source_sr", value: String(sourceRate)),
            URLQueryItem(name: "steps", value: "2"),   // MeanVC only; X-VC ignores it
        ]
        // WS clients can't set request headers reliably, so the token rides in the query
        // string (the README).
        if !token.isEmpty { components.queryItems?.append(URLQueryItem(name: "token", value: token)) }

        let task = session.webSocketTask(with: components.url!)
        task.resume()

        let hello = try await task.receive()
        guard case .string(let text) = hello else {
            throw XVCError("expected a JSON handshake frame, got binary")
        }
        let json = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] ?? [:]
        if let error = json["error"] as? String {
            task.cancel(with: .normalClosure, reason: nil)
            throw XVCError("server refused the session: \(error)")   // e.g. "Unknown target_id"
        }
        guard json["status"] as? String == "ready" else {
            throw XVCError("unexpected handshake: \(text)")
        }
        return task
    }

    /// Dev-only trust override for the KTH server's self-signed cert (the README).
    /// Gated behind --insecure and scoped to the one host we were pointed at; never ship a
    /// build where this can fire by default.
    public func urlSession(_ session: URLSession,
                    didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        guard allowSelfSigned,
              challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              challenge.protectionSpace.host == host,
              let trust = challenge.protectionSpace.serverTrust else {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        completionHandler(.useCredential, URLCredential(trust: trust))
    }
}

/// Pumps binary frames out of the socket until it closes. Text frames are `{"error": …}`
/// and are fatal for the session.
public func receiveLoop(_ task: URLSessionWebSocketTask,
                 onPCM: @escaping ([Float], Double) -> Void,
                 onClose: @escaping (String?) -> Void) {
    task.receive { result in
        switch result {
        case .failure(let error):
            onClose(error.localizedDescription)
        case .success(let message):
            switch message {
            case .data(let data):
                let now = machNow()   // stamp on arrival, before any queueing
                let pcm = data.withUnsafeBytes { raw -> [Float] in
                    Array(raw.bindMemory(to: Float.self))
                }
                onPCM(pcm, now)
                receiveLoop(task, onPCM: onPCM, onClose: onClose)
            case .string(let text):
                onClose(text)
            @unknown default:
                receiveLoop(task, onPCM: onPCM, onClose: onClose)
            }
        }
    }
}
