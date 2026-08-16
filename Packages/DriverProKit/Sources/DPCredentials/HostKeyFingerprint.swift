//
//  HostKeyFingerprint.swift
//  DPCredentials
//

import CryptoKit
import Foundation

/// Renders an SSH public key as the fingerprint string a user can actually compare.
///
/// This exists so the host key prompt is not theatre. When DriverPro shows
/// `SHA256:PFM0y4QH3DQRNtkRP9ouT+ORYemBoaskM8VEAgF/GUk`, a user must be able to run
/// `ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub` on the server and compare character for
/// character. If our format differed in any way — padding, hex instead of base64, a different hash —
/// the comparison would silently fail and the prompt would be a rubber stamp.
///
/// The format was verified empirically against `ssh-keygen -lf`, not inferred from the RFC.
///
/// ## The wire format
/// An SSH public key blob is the same bytes that appear, base64-encoded, in the middle field of an
/// `authorized_keys` or `.pub` line:
///
/// ```
/// ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIG61sTbGdM8Bhw… user@host
///             └── base64 of the blob ──┘
/// ```
///
/// The blob itself is a sequence of length-prefixed SSH strings: a 4-byte big-endian length, the
/// algorithm name, then the key material. There is no *outer* length prefix — a detail that matters,
/// because hashing one extra four-byte header produces a plausible-looking fingerprint that matches
/// nothing.
public enum HostKeyFingerprint {

    /// The OpenSSH SHA-256 fingerprint of a public key blob.
    ///
    /// Returns the full display string including the `SHA256:` prefix, with base64 padding removed —
    /// both exactly as OpenSSH renders them.
    ///
    /// - Parameter keyBlob: The raw public key blob, as written by NIOSSH's `writeSSHHostKey` or
    ///   decoded from the base64 field of a `.pub` file.
    /// - Returns: A string such as `"SHA256:PFM0y4QH3DQRNtkRP9ouT+ORYemBoaskM8VEAgF/GUk"`.
    public static func sha256(ofKeyBlob keyBlob: Data) -> String {
        let digest = SHA256.hash(data: keyBlob)

        // OpenSSH strips the base64 padding. Keeping it would append "=" and break a character-for-
        // character comparison against ssh-keygen for every key whose digest length is not a multiple
        // of three — which is all of them, since SHA-256 is 32 bytes.
        let encoded = Data(digest).base64EncodedString().replacingOccurrences(of: "=", with: "")
        return "SHA256:\(encoded)"
    }

    /// The algorithm name recorded inside a key blob, such as `"ssh-ed25519"`.
    ///
    /// Read from the blob itself rather than from the surrounding text, so a mislabelled `known_hosts`
    /// line cannot make the prompt claim the wrong algorithm.
    ///
    /// - Parameter keyBlob: The raw public key blob.
    /// - Returns: The algorithm name, or `nil` if the blob is too short or not valid UTF-8.
    public static func algorithmName(ofKeyBlob keyBlob: Data) -> String? {
        // The blob opens with a 4-byte big-endian length followed by that many bytes of algorithm name.
        guard keyBlob.count >= 4 else { return nil }

        let length = keyBlob.prefix(4).reduce(into: UInt32(0)) { $0 = ($0 << 8) | UInt32($1) }
        guard length > 0, length <= 64, keyBlob.count >= 4 + Int(length) else { return nil }

        return String(data: keyBlob.dropFirst(4).prefix(Int(length)), encoding: .utf8)
    }
}
