//
//  WebDAVConnectionDelegate.swift
//  DPProtocolWebDAV
//

import DPCore
import Foundation
import Security

/// What every WebDAV session needs from a delegate: credentials that survive a redirect, and an answer
/// when the system will not vouch for the server's certificate.
///
/// One type for both because every session in this backend needs both — the transport's, and the ones a
/// download and an upload each build for themselves.
///
/// # Credentials across a redirect
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
///
/// ## The second thing that goes wrong with the same redirect
/// Behind a TLS terminator the redirect does not merely lose its credentials — it points at the wrong
/// scheme, because the origin server does not know TLS was ever involved. ``keepingOurScheme(_:from:)``
/// repairs that before any of the above is decided, and explains why it is safe to.
///
/// # Trusting a certificate the system will not
///
/// The system evaluates the certificate first, and when it is satisfied nobody is asked anything. When
/// it is not, ``TrustDecider`` is consulted — which checks what has been accepted before and only then
/// puts the question to the user. The same division of labour as `HostKeyVerifier`, which is why
/// `CredentialCoordinator` does no `known_hosts` lookup of its own.
class WebDAVConnectionDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {

    /// The `Authorization` header value to re-attach, if there is one.
    let authorization: String?

    /// Who decides about a certificate the system refused. `nil` means refuse it.
    let trust: TrustDecider?

    /// Creates a delegate.
    ///
    /// - Parameters:
    ///   - authorization: The header value, or `nil` for an anonymous server.
    ///   - trust: Who to ask about an untrusted certificate.
    init(authorization: String?, trust: TrustDecider? = nil) {
        self.authorization = authorization
        self.trust = trust
    }

    // MARK: - Server trust

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let serverTrust = challenge.protectionSpace.serverTrust,
              let trust else {
            // Anything else — Basic, Digest, a client certificate — is left to URLSession, which for a
            // pre-emptively authenticated request means answering the 401 rather than retrying blindly.
            completionHandler(.performDefaultHandling, nil)
            return
        }

        // The system first. A certificate it accepts raises no question at all, which is the common case
        // and must stay silent.
        var error: CFError?
        if SecTrustEvaluateWithError(serverTrust, &error) {
            completionHandler(.performDefaultHandling, nil)
            return
        }

        // Everything that touches Security.framework happens here, synchronously, so only Swift values
        // cross into the task below. `SecTrust` is a C type and not `Sendable`; reading it first is both
        // what satisfies the compiler and the better shape — `TrustDecider` never sees a CF object.
        guard let summary = CertificateDetails.summarise(serverTrust) else {
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }
        let problems = CertificateDetails.problems(from: error as (any Error)?, summary: summary)

        // The callback is synchronous and asking a person is not, so the answer is awaited in a task and
        // delivered when it arrives. URLSession waits as long as it takes.
        //
        // `Answer` carries the two ObjC objects that cannot cross a task boundary on their own — the
        // completion block and the credential — with the promise that the block is called exactly once,
        // which is what the API requires anyway.
        let space = challenge.protectionSpace
        let answer = Answer(completionHandler, credential: URLCredential(trust: serverTrust))

        Task {
            let accepted = await trust.shouldTrust(
                summary, problems: problems, hostname: space.host, port: space.port
            )
            answer.deliver(accepted)
        }
    }

    /// Carries a challenge's completion handler into the task that will answer it.
    ///
    /// `@unchecked Sendable` with a narrow justification: the block is called exactly once, which is the
    /// contract `URLSession` states for it, and nothing else reads the stored value.
    private final class Answer: @unchecked Sendable {
        private let handler: (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
        private let credential: URLCredential

        init(
            _ handler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void,
            credential: URLCredential
        ) {
            self.handler = handler
            self.credential = credential
        }

        func deliver(_ accepted: Bool) {
            accepted
                ? handler(.useCredential, credential)
                : handler(.cancelAuthenticationChallenge, nil)
        }
    }

    // MARK: - Redirects

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        guard let original = task.originalRequest?.url else {
            completionHandler(request)
            return
        }

        let next = Self.keepingOurScheme(request, from: original)

        guard let authorization, Self.isSameOrigin(original, next.url) else {
            completionHandler(next)
            return
        }

        var authenticated = next
        authenticated.setValue(authorization, forHTTPHeaderField: "Authorization")
        completionHandler(authenticated)
    }

    /// Puts `https` back when the server redirects us to `http` on the same host and port.
    ///
    /// ## The problem
    /// A WebDAV server behind a TLS terminator — Caddy, nginx, a load balancer — usually does not know
    /// it is behind one. Apache builds its trailing-slash redirect from *its own* scheme, so a request
    /// to `https://host:8443/folder` is answered with `Location: http://host:8443/folder/`. That port
    /// speaks TLS only, so following it sends plaintext to a TLS listener and the proxy hangs up. The
    /// error reaching the user is `NSURLErrorNetworkConnectionLost` — "the network connection was
    /// lost" — which says nothing about a redirect and points at the network rather than the server.
    ///
    /// It disables every collection operation that does not end its URL in a slash: `stat`, `exists`,
    /// `delete` and `move`. Not `list`, which passes `isDirectory: true` — which is why the symptom is
    /// the baffling one of browsing working perfectly and deleting a folder failing.
    ///
    /// ## Why repairing it is safe
    /// The rewrite only ever keeps the *more* secure scheme, and only when the host and port are
    /// unchanged — so it cannot send us somewhere new, and it cannot downgrade. A redirect that
    /// genuinely changes host is left alone for `URLSession` to handle, credentials stripped.
    ///
    /// - Parameters:
    ///   - request: The redirect `URLSession` proposes to follow.
    ///   - original: Where the request that was redirected went.
    /// - Returns: The request, with `https` restored if it had been dropped.
    static func keepingOurScheme(_ request: URLRequest, from original: URL) -> URLRequest {
        guard original.scheme?.lowercased() == "https",
              let target = request.url,
              target.scheme?.lowercased() == "http",
              target.host()?.lowercased() == original.host()?.lowercased(),
              target.port == original.port,
              var components = URLComponents(url: target, resolvingAgainstBaseURL: false)
        else { return request }

        components.scheme = "https"
        guard let secure = components.url else { return request }

        var repaired = request
        repaired.url = secure
        return repaired
    }

    /// Whether two URLs are the same server, by scheme, host and port.
    ///
    /// Compared rather than assumed: a redirect to another host is exactly the case where the
    /// credentials must not follow. The scheme counts too — credentials that follow an `https` request
    /// onto plain `http` are credentials put on the wire in near-clear, and WebDAV's are Basic.
    static func isSameOrigin(_ one: URL, _ other: URL?) -> Bool {
        guard let other else { return false }
        return one.scheme == other.scheme
            && one.host()?.lowercased() == other.host()?.lowercased()
            && one.port == other.port
    }
}
