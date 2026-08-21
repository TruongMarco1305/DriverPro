//
//  CertificateDetails.swift
//  DPProtocolWebDAV
//

import DPCore
import CryptoKit
import Foundation
import Security

/// Reads a server's certificate well enough to describe it to a person.
///
/// Every part of this is `Security.framework`'s C API, which is why it is confined to one file: the rest
/// of the backend deals in Swift values. The fingerprint is checked against `openssl x509 -fingerprint
/// -sha256` in the tests rather than against our own arithmetic — a hash that is self-consistently wrong
/// is worse than no hash, because it looks authoritative.
enum CertificateDetails {

    /// What could be read from the certificate a server offered.
    struct Summary: Sendable {
        /// SHA-256 of the DER, spelled `"SHA256:…"` as host key fingerprints are.
        var fingerprint: String
        /// Who it was issued to.
        var subject: String
        /// Who issued it.
        var issuer: String
        /// When it stops being valid.
        var expiresAt: Date?
        /// Whether the issuer is itself.
        var isSelfSigned: Bool
    }

    /// Describes the leaf certificate of a trust object.
    ///
    /// - Parameter trust: The trust the system was evaluating.
    /// - Returns: What could be read, or `nil` if there is no certificate in it at all.
    static func summarise(_ trust: SecTrust) -> Summary? {
        guard let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate],
              let leaf = chain.first else { return nil }

        let subject = (SecCertificateCopySubjectSummary(leaf) as String?) ?? "unknown"
        let issuer = issuerName(of: leaf) ?? subject

        return Summary(
            fingerprint: fingerprint(of: leaf),
            subject: subject,
            issuer: issuer,
            expiresAt: expiry(of: leaf),
            // Compared by name rather than by verifying the signature: this decides how the sheet
            // describes the certificate, not whether to trust it. The system already decided that.
            isSelfSigned: issuer == subject
        )
    }

    /// The SHA-256 fingerprint of a certificate's DER encoding.
    ///
    /// The DER *is* the certificate — the same bytes any other tool hashes — so this can be compared
    /// against what `openssl` prints, which is the only way to know it is right.
    static func fingerprint(of certificate: SecCertificate) -> String {
        let der = SecCertificateCopyData(certificate) as Data
        let digest = SHA256.hash(data: der)
        let hex = digest.map { String(format: "%02X", $0) }.joined(separator: ":")
        return "SHA256:\(hex)"
    }

    /// Why the system refused a certificate.
    ///
    /// Read from the error it produced rather than guessed at, because the difference matters to the
    /// user: an expired certificate needs renewing, a name mismatch means they are somewhere unexpected,
    /// and a self-signed one on a server they run is entirely normal.
    ///
    /// - Parameters:
    ///   - error: What `SecTrustEvaluateWithError` reported.
    ///   - summary: What was read from the certificate.
    /// - Returns: Every problem that could be identified. Empty means the system did not say.
    static func problems(from error: (any Error)?, summary: Summary?) -> Set<CertificateChallenge.Problem> {
        var found: Set<CertificateChallenge.Problem> = []

        // `SecTrustEvaluateWithError` puts a sentence in the error rather than a code per cause, so this
        // reads it. Coarse, and honest about being coarse: an unmatched reason yields no problem rather
        // than a wrong one, and the sheet then says only that the system refused it.
        let description = (error?.localizedDescription ?? "").lowercased()

        if description.contains("expired") { found.insert(.expired) }
        if description.contains("not yet valid") || description.contains("not valid until") {
            found.insert(.notYetValid)
        }
        if description.contains("host") && description.contains("match") {
            found.insert(.hostnameMismatch)
        }

        if let summary {
            // Checked directly as well: the system reports the *first* thing that stopped it, so a
            // self-signed certificate that also expired mentions only one of them.
            if summary.isSelfSigned {
                found.insert(.selfSigned)
            } else if description.contains("root") || description.contains("authority")
                        || description.contains("chain") {
                found.insert(.untrustedRoot)
            }
            if let expiresAt = summary.expiresAt, expiresAt < Date() {
                found.insert(.expired)
            }
        }
        return found
    }

    // MARK: - Reading the certificate itself

    /// The issuer's common name.
    ///
    /// `SecCertificateCopyValues` returns a dictionary of dictionaries keyed by OID, which is why this
    /// is five lines to read one string.
    private static func issuerName(of certificate: SecCertificate) -> String? {
        guard let values = SecCertificateCopyValues(
            certificate, [kSecOIDX509V1IssuerName] as CFArray, nil
        ) as? [String: Any],
            let issuer = values[kSecOIDX509V1IssuerName as String] as? [String: Any],
            let parts = issuer[kSecPropertyKeyValue as String] as? [[String: Any]]
        else { return nil }

        // The common name, or failing that whatever the last component is — an issuer with no CN is
        // unusual but not impossible, and something is better than "unknown".
        let commonName = parts.first { $0[kSecPropertyKeyLabel as String] as? String == "2.5.4.3" }
        let chosen = commonName ?? parts.last
        return chosen?[kSecPropertyKeyValue as String] as? String
    }

    /// When the certificate stops being valid.
    private static func expiry(of certificate: SecCertificate) -> Date? {
        guard let values = SecCertificateCopyValues(
            certificate, [kSecOIDX509V1ValidityNotAfter] as CFArray, nil
        ) as? [String: Any],
            let validity = values[kSecOIDX509V1ValidityNotAfter as String] as? [String: Any],
            let interval = validity[kSecPropertyKeyValue as String] as? Double
        else { return nil }

        // Seconds since 2001, not 1970: this is a CFAbsoluteTime, and reading it as a Unix timestamp
        // puts every certificate's expiry in 1970 — which looks like a parsing success.
        return Date(timeIntervalSinceReferenceDate: interval)
    }
}
