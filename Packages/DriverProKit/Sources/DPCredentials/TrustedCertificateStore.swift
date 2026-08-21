//
//  TrustedCertificateStore.swift
//  DPCredentials
//

import DPCore
import Foundation

/// What is on record about a server's certificate.
///
/// The same three answers `HostKeyTrust` gives, for the same reason: the caller needs to know whether to
/// stay quiet, ask a mild question, or ask a serious one.
public enum CertificateTrust: Hashable, Sendable {
    /// Nothing on record for this host. Trust on first use.
    case unknown
    /// This exact certificate was accepted before. Connect without asking.
    case trusted
    /// A *different* certificate was accepted for this host. Carries the stored fingerprint so both can
    /// be shown side by side.
    case mismatch(storedFingerprint: String)
}

/// One certificate the user chose to trust.
public struct TrustedCertificate: Hashable, Sendable, Codable {

    /// The server it was accepted for.
    public var hostname: String
    /// The port it was accepted on. A different port is a different server for this purpose.
    public var port: Int
    /// SHA-256 fingerprint, `"SHA256:…"`.
    public var fingerprint: String
    /// Who it was issued to, kept so the file is readable by a person.
    public var subject: String
    /// Who issued it.
    public var issuer: String
    /// When the user accepted it, so a stale record can be recognised as old.
    public var acceptedAt: Date

    /// Creates a record.
    ///
    /// - Parameters:
    ///   - hostname: The server.
    ///   - port: The port.
    ///   - fingerprint: SHA-256 fingerprint.
    ///   - subject: Who it was issued to.
    ///   - issuer: Who issued it.
    ///   - acceptedAt: When it was accepted. Defaults to now.
    public init(
        hostname: String,
        port: Int,
        fingerprint: String,
        subject: String = "",
        issuer: String = "",
        acceptedAt: Date = Date()
    ) {
        self.hostname = hostname
        self.port = port
        self.fingerprint = fingerprint
        self.subject = subject
        self.issuer = issuer
        self.acceptedAt = acceptedAt
    }
}

/// Certificates the user has accepted that the system would not.
///
/// The counterpart to `KnownHostsStore`, and deliberately the same idea: a plain file recording what was
/// trusted, consulted before anyone is asked, so a server is only ever questioned once.
///
/// **A file rather than the Keychain**, because none of this is secret — it is a record of a decision.
/// **A file rather than the database**, because when something goes wrong with trust the useful thing a
/// person can do is open it, look, and delete a line. That is what people do with `known_hosts`, and it
/// is why that file has outlived every attempt to improve on it.
///
/// See `docs/decisions/015-certificate-trust.md`.
public actor TrustedCertificateStore {

    private let fileURL: URL

    /// Where the file lives by default.
    public static var defaultFileURL: URL {
        URL.applicationSupportDirectory.appending(path: "DriverPro/trusted-certificates.json")
    }

    /// Creates a store.
    /// - Parameter fileURL: Where to keep the records. Defaults to ``defaultFileURL``.
    public init(fileURL: URL? = nil) {
        self.fileURL = fileURL ?? Self.defaultFileURL
    }

    // MARK: - Reading

    /// Every record, in the order they were written.
    ///
    /// A file that cannot be read at all yields nothing rather than throwing: an absent file is the
    /// normal state before anything has been accepted, and a corrupt one should not stop the app
    /// connecting to servers the system already trusts.
    ///
    /// - Returns: What is on record.
    public func entries() -> [TrustedCertificate] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }

        let decoder = JSONDecoder()
        // Must match the encoder: dates are written as ISO 8601 so the file reads like a document rather
        // than a dump. Leaving this at the default reads every record back as unparseable, which looks
        // exactly like an empty store — silently forgetting everything the user trusted.
        decoder.dateDecodingStrategy = .iso8601

        return (try? decoder.decode([TrustedCertificate].self, from: data)) ?? []
    }

    /// What is known about a server's certificate.
    ///
    /// - Parameters:
    ///   - hostname: The server.
    ///   - port: The port.
    ///   - fingerprint: The fingerprint being offered.
    /// - Returns: Whether it is unknown, already trusted, or different from what was accepted before.
    public func trust(hostname: String, port: Int, fingerprint: String) -> CertificateTrust {
        let onRecord = entries().filter {
            $0.hostname.caseInsensitiveCompare(hostname) == .orderedSame && $0.port == port
        }

        guard let stored = onRecord.first else { return .unknown }
        // Any match counts as trusted: a server may legitimately serve more than one certificate, and a
        // renewal accepted alongside the old one should not read as an impersonation.
        if onRecord.contains(where: { $0.fingerprint == fingerprint }) { return .trusted }
        return .mismatch(storedFingerprint: stored.fingerprint)
    }

    // MARK: - Writing

    /// Records a certificate as trusted, replacing any earlier one for the same server.
    ///
    /// Replacing rather than appending: keeping the old fingerprint would mean an impersonator who once
    /// had a certificate accepted stays trusted forever. A renewal is the common case, and the user has
    /// just been shown both and chosen.
    ///
    /// - Parameter certificate: What to record.
    /// - Throws: ``CertificateStoreError/fileUnavailable(path:reason:)`` if it cannot be written.
    public func store(_ certificate: TrustedCertificate) throws {
        var records = entries().filter {
            !($0.hostname.caseInsensitiveCompare(certificate.hostname) == .orderedSame
              && $0.port == certificate.port)
        }
        records.append(certificate)
        try write(records)
    }

    /// Forgets every certificate recorded for a server.
    ///
    /// - Parameters:
    ///   - hostname: The server.
    ///   - port: The port.
    /// - Throws: ``CertificateStoreError/fileUnavailable(path:reason:)`` if the file cannot be written.
    public func forget(hostname: String, port: Int) throws {
        try write(entries().filter {
            !($0.hostname.caseInsensitiveCompare(hostname) == .orderedSame && $0.port == port)
        })
    }

    private func write(_ records: [TrustedCertificate]) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601      // so a person reading the file can read the dates

        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try encoder.encode(records).write(to: fileURL, options: .atomic)
        } catch {
            throw CertificateStoreError.fileUnavailable(
                path: fileURL.path, reason: error.localizedDescription
            )
        }
    }
}

/// Failures specific to the trusted certificate file.
public enum CertificateStoreError: Error, Hashable, Sendable {
    /// The file could not be written.
    case fileUnavailable(path: String, reason: String)
}

extension CertificateStoreError: LocalizedError {
    /// A message naming the file that could not be used.
    public var errorDescription: String? {
        switch self {
        case .fileUnavailable(let path, let reason):
            "Could not record the trusted certificate at \(path): \(reason)"
        }
    }
}
