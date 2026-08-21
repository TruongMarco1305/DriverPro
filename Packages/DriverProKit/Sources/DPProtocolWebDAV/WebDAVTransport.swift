//
//  WebDAVTransport.swift
//  DPProtocolWebDAV
//

import DPCore
import Foundation

/// The WebDAV verbs, over `URLSession`.
///
/// Everything protocol-specific about *speaking* to the server is here — methods, headers, and what a
/// status code means — so ``WebDAVSession`` is left saying what the operations are rather than how they
/// travel. The split matters because HTTP status handling is where the fiddly, well-documented rules
/// live, and they are worth reading in one place.
struct WebDAVTransport: Sendable {

    /// The verbs WebDAV adds to HTTP, plus the ones it borrows.
    enum Method: String {
        case propfind = "PROPFIND"
        case mkcol = "MKCOL"
        case delete = "DELETE"
        case move = "MOVE"
        case copy = "COPY"
        case get = "GET"
        case put = "PUT"
        case head = "HEAD"
        case options = "OPTIONS"
    }

    private let session: URLSession
    private let credentials: String?

    /// Creates a transport.
    ///
    /// - Parameters:
    ///   - session: The `URLSession` to send on. Injected so a test can supply a stubbed protocol.
    ///   - username: Account name, if the server wants one.
    ///   - password: Its password.
    init(session: URLSession, username: String?, password: String?) {
        self.session = session

        // Basic, pre-emptively, rather than waiting to be challenged. A `URLSession` challenge handler
        // would work for one request at a time, but WebDAV sends many small ones and paying a 401 round
        // trip for each doubles the cost of every listing. Nextcloud app passwords are Basic too.
        if let username, let password {
            let pair = Data("\(username):\(password)".utf8).base64EncodedString()
            self.credentials = "Basic \(pair)"
        } else {
            self.credentials = nil
        }
    }

    // MARK: - Sending

    /// Sends a request and returns the body.
    ///
    /// - Parameters:
    ///   - method: The verb.
    ///   - url: Where to send it.
    ///   - path: What this is about, for the error if it fails.
    ///   - headers: Extra headers, such as `Depth` or `Destination`.
    ///   - body: The request body, if any.
    /// - Returns: The response body and its metadata.
    /// - Throws: ``SessionError`` mapped from the status code.
    @discardableResult
    func send(
        _ method: Method,
        to url: URL,
        about path: RemotePath,
        headers: [String: String] = [:],
        body: Data? = nil
    ) async throws -> (data: Data, response: HTTPURLResponse) {
        var request = URLRequest(url: url)
        request.httpMethod = method.rawValue
        request.httpBody = body
        if let credentials { request.setValue(credentials, forHTTPHeaderField: "Authorization") }
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError {
            throw Self.mapURLError(error, host: url.host() ?? "the server")
        } catch {
            throw SessionError.transport(error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else {
            throw SessionError.protocolViolation("The server did not answer with HTTP.")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw Self.mapStatus(http.statusCode, path: path)
        }
        return (data, http)
    }

    // MARK: - Mapping failures

    /// What an HTTP status means for a file operation.
    ///
    /// The interesting ones are 405 and 409, which say different things depending on the verb — `MKCOL`
    /// answers 405 for "already there", while a `PUT` to a path whose parent is missing answers 409.
    /// Both are mapped to the error that names the actual problem, because "method not allowed" is not
    /// something a user can act on.
    static func mapStatus(_ status: Int, path: RemotePath) -> SessionError {
        switch status {
        case 401, 403:
            // 401 is "who are you", 403 is "not you". The first is worth retrying with new credentials
            // and the second is not, which is why they map differently.
            status == 401
                ? .authenticationFailed(reason: "The server rejected the user name or password.")
                : .accessDenied(path)
        case 404, 410:
            .notFound(path)
        case 405:
            .alreadyExists(path)
        case 409:
            .notFound(path.parent ?? .root)
        case 412:
            .alreadyExists(path)
        case 423:
            .accessDenied(path)
        case 507:
            .insufficientStorage
        case 501:
            .unsupported([], operation: "this operation")
        default:
            .transport("The server answered \(status).")
        }
    }

    /// What a networking failure means, in words a user can act on.
    static func mapURLError(_ error: URLError, host: String) -> SessionError {
        switch error.code {
        case .timedOut:
            .timedOut
        case .cancelled:
            .cancelled
        case .userAuthenticationRequired:
            .authenticationFailed(reason: "The server asked for credentials.")
        case .cannotFindHost, .cannotConnectToHost, .networkConnectionLost, .notConnectedToInternet,
             .dnsLookupFailed:
            .unreachable(host: host, reason: error.localizedDescription)
        case .secureConnectionFailed, .serverCertificateUntrusted, .serverCertificateHasBadDate,
             .serverCertificateHasUnknownRoot, .serverCertificateNotYetValid:
            // Slice 3c turns this into a question rather than a refusal; until then it at least says
            // which of the several TLS problems it is.
            .transport("The server's certificate could not be verified: \(error.localizedDescription)")
        default:
            .transport(error.localizedDescription)
        }
    }
}
