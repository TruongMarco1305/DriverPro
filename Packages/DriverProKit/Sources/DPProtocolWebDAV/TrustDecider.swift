//
//  TrustDecider.swift
//  DPProtocolWebDAV
//

import DPCore
import DPCredentials
import Foundation

/// Decides whether to proceed with a certificate the system refused.
///
/// Sits between the URLSession delegate, which must answer synchronously and knows nothing about the
/// user, and the `SessionDelegate`, which can ask one. In between it consults what has already been
/// accepted, so the question is only put when it genuinely cannot be answered from record.
///
/// **Two kinds of memory**, and the distinction is the point:
///
/// - `acceptAndStore` writes to `TrustedCertificateStore` and is remembered across launches.
/// - `acceptOnce` is remembered **here**, in memory, for as long as this object lives — which is the
///   lifetime of one `WebDAVSession`. A download and an upload each build their own `URLSession`, so
///   without this "just this once" would mean "once per request" and a tree upload would ask fifty
///   times. It is still never written down, so it is forgotten when the connection closes.
actor TrustDecider {

    private let host: RemoteHost
    private let store: TrustedCertificateStore
    private let delegate: any SessionDelegate

    /// Fingerprints accepted for this connection only, by `acceptOnce`.
    private var acceptedForThisConnection: Set<String> = []

    /// Questions already in flight, so several requests hitting the same untrusted server at once ask
    /// the user once rather than once each.
    private var inFlight: [String: Task<Bool, Never>] = [:]

    /// Creates a decider.
    ///
    /// - Parameters:
    ///   - host: The bookmark being connected to, passed to the delegate with the question.
    ///   - store: What has been accepted before.
    ///   - delegate: Who to ask when the record does not settle it.
    init(host: RemoteHost, store: TrustedCertificateStore, delegate: any SessionDelegate) {
        self.host = host
        self.store = store
        self.delegate = delegate
    }

    /// Whether to proceed with this certificate.
    ///
    /// Takes what was read from the certificate rather than the certificate itself, so nothing in here
    /// touches `Security.framework` — the C types are read on the delegate's thread and only Swift
    /// values cross into this actor.
    ///
    /// - Parameters:
    ///   - summary: What the certificate says about itself.
    ///   - problems: Why the system refused it.
    ///   - hostname: The server, as the connection addressed it.
    ///   - port: The port.
    /// - Returns: Whether to go ahead.
    func shouldTrust(
        _ summary: CertificateDetails.Summary,
        problems: Set<CertificateChallenge.Problem>,
        hostname: String,
        port: Int
    ) async -> Bool {
        if acceptedForThisConnection.contains(summary.fingerprint) { return true }

        let recorded = await store.trust(
            hostname: hostname, port: port, fingerprint: summary.fingerprint
        )
        if case .trusted = recorded { return true }

        // One question per certificate, however many requests are waiting on the answer.
        if let existing = inFlight[summary.fingerprint] { return await existing.value }

        let question = Task { [weak self] in
            guard let self else { return false }
            return await ask(summary: summary, problems: problems,
                             hostname: hostname, port: port, recorded: recorded)
        }
        inFlight[summary.fingerprint] = question

        let answer = await question.value
        inFlight[summary.fingerprint] = nil
        return answer
    }

    private func ask(
        summary: CertificateDetails.Summary,
        problems: Set<CertificateChallenge.Problem>,
        hostname: String,
        port: Int,
        recorded: CertificateTrust
    ) async -> Bool {
        let challenge = CertificateChallenge(
            hostname: hostname,
            port: port,
            subject: summary.subject,
            issuer: summary.issuer,
            fingerprint: summary.fingerprint,
            expiresAt: summary.expiresAt,
            problems: problems,
            trust: {
                if case .mismatch(let stored) = recorded { return .changed(previousFingerprint: stored) }
                return .unknown
            }()
        )

        switch await delegate.session(host, needsCertificateVerification: challenge) {
        case .reject:
            return false

        case .acceptOnce:
            acceptedForThisConnection.insert(summary.fingerprint)
            return true

        case .acceptAndStore:
            acceptedForThisConnection.insert(summary.fingerprint)
            // A failure to write is not a reason to refuse a connection the user just approved — it
            // means the next launch asks again, which is a nuisance rather than a fault.
            try? await store.store(TrustedCertificate(
                hostname: hostname,
                port: port,
                fingerprint: summary.fingerprint,
                subject: summary.subject,
                issuer: summary.issuer
            ))
            return true
        }
    }
}
