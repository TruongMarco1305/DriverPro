//
//  WebDAVRedirectAuthenticator.swift
//  DPProtocolWebDAV
//

import Foundation

/// Re-attaches credentials when a request is redirected within the same server.
///
/// ## The problem this solves
/// Apache answers a *collection* requested without a trailing slash with a 301 to the slashed form —
/// `DELETE /photos` becomes `DELETE /photos/`. `URLSession` follows the redirect automatically and
/// **drops the `Authorization` header when it does**, so the second request arrives anonymous and the
/// server answers 401. The symptom is baffling: browsing works, and deleting a folder reports the
/// password is wrong.
///
/// Dropping the header is right of `URLSession` in general — following a redirect to another host with
/// your credentials attached is how they leak. So this puts them back only when the redirect stays on
/// the same scheme, host and port, and lets `URLSession`'s caution stand everywhere else.
///
/// Avoiding the redirect instead would mean knowing whether every path is a collection before asking
/// about it, which costs a round trip per operation to save one that only happens sometimes.
class WebDAVRedirectAuthenticator: NSObject, URLSessionTaskDelegate, @unchecked Sendable {

    /// The `Authorization` header value to re-attach, if there is one.
    let authorization: String?

    /// Creates an authenticator.
    /// - Parameter authorization: The header value, or `nil` for an anonymous server.
    init(authorization: String?) {
        self.authorization = authorization
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        guard let authorization,
              let original = task.originalRequest?.url,
              Self.isSameOrigin(original, request.url) else {
            completionHandler(request)
            return
        }

        var authenticated = request
        authenticated.setValue(authorization, forHTTPHeaderField: "Authorization")
        completionHandler(authenticated)
    }

    /// Whether two URLs are the same server, by scheme, host and port.
    ///
    /// Compared rather than assumed: a redirect to another host is exactly the case where the
    /// credentials must not follow.
    static func isSameOrigin(_ one: URL, _ other: URL?) -> Bool {
        guard let other else { return false }
        return one.scheme == other.scheme
            && one.host()?.lowercased() == other.host()?.lowercased()
            && one.port == other.port
    }
}
