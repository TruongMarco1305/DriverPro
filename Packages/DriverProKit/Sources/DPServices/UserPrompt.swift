//
//  UserPrompt.swift
//  DPServices
//

import DPCore
import Foundation

/// The questions a connection may need a human to answer.
///
/// The app implements this with sheets; tests implement it with canned answers. It is the only way the
/// engine can reach a person, which is what keeps `DriverProKit` free of any UI framework.
///
/// Every method returns an optional or a decision rather than throwing, because "the user cancelled" is
/// an answer, not a failure.
public protocol UserPrompt: Sendable {

    /// Asks whether to trust a server's host key.
    ///
    /// Only called when `known_hosts` cannot answer — an already-trusted key never reaches here, which
    /// is what stops people learning to dismiss the prompt without reading it.
    ///
    /// - Parameters:
    ///   - challenge: The key being offered and what is known about it.
    ///   - host: The connection being established.
    /// - Returns: Whether to reject, accept once, or accept and remember.
    func askHostKey(_ challenge: HostKeyChallenge, for host: RemoteHost) async -> HostKeyDecision

    /// Asks whether to trust a server's TLS certificate.
    ///
    /// Only called when the system has already refused it *and* nothing on record settles the matter —
    /// the same rule as ``askHostKey(_:for:)``, and for the same reason: a prompt that appears when it
    /// need not is a prompt people learn to dismiss.
    ///
    /// - Parameters:
    ///   - challenge: The certificate being offered, why it was refused, and what is known about it.
    ///   - host: The connection being established.
    /// - Returns: Whether to reject, accept once, or accept and remember.
    func askCertificate(_ challenge: CertificateChallenge, for host: RemoteHost) async -> CertificateDecision

    /// Asks for credentials.
    ///
    /// - Parameter request: Why credentials are needed, and for which connection.
    /// - Returns: What to try, or `nil` if the user cancelled.
    func askCredentials(_ request: CredentialRequest) async -> Credentials?

    /// Answers an SSH keyboard-interactive challenge, the usual carrier for one-time MFA codes.
    ///
    /// - Parameters:
    ///   - prompts: The server's questions, paired with whether the answer should be echoed.
    ///   - host: The connection being established.
    /// - Returns: One answer per prompt, in order, or `nil` if the user cancelled.
    func askKeyboardInteractive(
        _ prompts: [(prompt: String, isEchoed: Bool)],
        for host: RemoteHost
    ) async -> [String]?
}

extension UserPrompt {
    /// Refuses an untrusted certificate by default.
    ///
    /// The safe answer, and the same one ``SessionDelegate`` defaults to: a prompt that has not been
    /// taught about certificates declines them rather than guessing. Every existing conformer — the test
    /// doubles especially — keeps working, and none of them silently starts accepting.
    public func askCertificate(
        _ challenge: CertificateChallenge,
        for host: RemoteHost
    ) async -> CertificateDecision {
        .reject
    }

    /// Declines keyboard-interactive authentication by default, so adopting the protocol needs two
    /// methods rather than three.
    public func askKeyboardInteractive(
        _ prompts: [(prompt: String, isEchoed: Bool)],
        for host: RemoteHost
    ) async -> [String]? {
        nil
    }
}
