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

    /// The `Authorization` header every request carries, and that a redirect must not lose.
    let credentials: String?

    /// Creates a transport, and the session it sends on.
    ///
    /// The session is built here rather than injected because it needs a delegate that knows the
    /// credentials — see ``WebDAVRedirectAuthenticator`` — and those are only known once the user has
    /// supplied them.
    ///
    /// - Parameters:
    ///   - configuration: The session configuration. A test installs a stubbed protocol through it.
    ///   - username: Account name, if the server wants one.
    ///   - password: Its password.
    ///   - trust: Who decides about a certificate the system refused.
    init(
        configuration: URLSessionConfiguration,
        username: String?,
        password: String?,
        trust: TrustDecider? = nil
    ) {
        // Basic, pre-emptively, rather than waiting to be challenged. A `URLSession` challenge handler
        // would work for one request at a time, but WebDAV sends many small ones and paying a 401 round
        // trip for each doubles the cost of every listing. Nextcloud app passwords are Basic too.
        if let username, let password {
            let pair = Data("\(username):\(password)".utf8).base64EncodedString()
            self.credentials = "Basic \(pair)"
        } else {
            self.credentials = nil
        }

        self.session = URLSession(
            configuration: configuration,
            delegate: WebDAVConnectionDelegate(authorization: credentials, trust: trust),
            delegateQueue: nil
        )
    }

    /// Finishes what is in flight and releases the session's delegate.
    func invalidate() {
        session.finishTasksAndInvalidate()
    }

    // MARK: - Building

    /// Builds a request, authenticated and ready to send.
    ///
    /// Exposed because streaming a download or an upload cannot go through ``send(_:to:about:headers:body:)``
    /// — those need the request itself, to hand to a delegate or a body stream — and the credentials
    /// should be attached in exactly one place regardless.
    ///
    /// - Parameters:
    ///   - method: The verb.
    ///   - url: Where to send it.
    /// - Returns: The request.
    func request(_ method: Method, to url: URL) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = method.rawValue
        if let credentials { request.setValue(credentials, forHTTPHeaderField: "Authorization") }
        return request
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
        var request = self.request(method, to: url)
        request.httpBody = body
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
            throw Self.mapStatus(http.statusCode, path: path, method: method)
        }
        return (data, http)
    }

    // MARK: - Mapping failures

    /// What an HTTP status means for a file operation.
    ///
    /// **The verb matters**, which is why it is a parameter rather than something this could work out
    /// from the status alone. 405 on a `MKCOL` means "there is already a folder called that"; on a
    /// `PROPFIND` it means the URL is not a WebDAV endpoint at all, which is a completely different
    /// problem with a completely different fix. Mapping it one way for every verb produced
    /// *"/ already exists."* when someone pointed DriverPro at a Nextcloud without its DAV root — an
    /// answer that is not merely unhelpful but actively misleading.
    ///
    /// - Parameters:
    ///   - status: The HTTP status.
    ///   - path: What the request was about, for the error that names it.
    ///   - method: The verb that was sent, which decides what several statuses mean.
    /// - Returns: The error to throw.
    static func mapStatus(_ status: Int, path: RemotePath, method: Method) -> SessionError {
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
            mapMethodNotAllowed(path: path, method: method)
        case 409:
            .notFound(path.parent ?? .root)
        case 412:
            // A precondition we set: `MKCOL` and an overwrite-refusing `MOVE` or `COPY` say "only if it
            // is not already there", so 412 from those means it is. From anything else it means the
            // server evaluated a condition we did not write, and saying "already exists" would be a
            // guess dressed as a fact.
            switch method {
            case .mkcol, .move, .copy, .put:
                .alreadyExists(path)
            default:
                .protocolViolation("The server refused the request on a condition it was not given.")
            }
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

    /// What a 405 means, which depends entirely on what was asked.
    ///
    /// - Parameters:
    ///   - path: What the request was about.
    ///   - method: The verb the server refused.
    /// - Returns: The error naming the actual problem.
    private static func mapMethodNotAllowed(path: RemotePath, method: Method) -> SessionError {
        switch method {
        case .mkcol:
            // The one case where 405 is routine: RFC 4918 says a MKCOL on an existing resource answers
            // "method not allowed", which for a user means the folder is already there.
            .alreadyExists(path)

        case .propfind:
            // A server that answers HTTP but refuses PROPFIND is not a WebDAV endpoint. Nearly always
            // this is a DAV root that is missing or wrong — pointing at the web front end of a
            // Nextcloud rather than at `/remote.php/dav/files/<user>` produces exactly this.
            .protocolViolation(
                "This address answers, but does not speak WebDAV. Check the WebDAV Path — "
                + "Nextcloud serves it at /remote.php/dav/files/<user>."
            )

        default:
            .unsupported([], operation: "\(method.rawValue) at this address")
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
