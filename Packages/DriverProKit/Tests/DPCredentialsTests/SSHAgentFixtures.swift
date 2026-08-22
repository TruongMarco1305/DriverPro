//
//  SSHAgentFixtures.swift
//  DPCredentialsTests
//

import Foundation

/// Bytes captured from a real `ssh-agent`, not written by hand.
///
/// This distinction is the whole value of the file. A test that runs our encoder into our decoder proves
/// only that the two agree with each other — which they would even if both were wrong about the format.
/// These bytes came off the wire from OpenSSH's own agent, so a test that parses them proves agreement
/// with the thing DriverPro actually has to talk to.
///
/// ## How they were captured
///
/// A throwaway agent and a throwaway key, so nothing here belongs to anybody:
///
/// ```sh
/// ssh-keygen -t ed25519 -N "" -C "throwaway fixture key" -f k
/// eval "$(ssh-agent -a ./s -s)" && ssh-add k
/// ```
///
/// Then a short Python script connected to `./s`, sent each request, and printed the reply as hex:
/// `REQUEST_IDENTITIES` (message 11) for the identity list; `SIGN_REQUEST` (13) with the key blob the
/// agent had just reported, over the payload `"driverpro fixture payload"`, for the signature; and the
/// same request with one bit flipped in the key blob, for the refusal.
///
/// The key was destroyed with the agent. It is a fixture, not a credential — and an Ed25519 *public* key
/// is not secret in any case.
enum SSHAgentFixtures {

    /// The throwaway key's public key line, for cross-checking what the agent reported.
    static let publicKeyLine =
        "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIF2xU23ADghgxNkBBB+5Eh5urgtPmQwWOZ5pKNc0D5Wg"
            + " throwaway fixture key"

    /// `ssh-keygen -lf` output for that key, to prove the fingerprint helper agrees with OpenSSH.
    static let expectedFingerprint = "SHA256:A5Ns+rQBMjIXt6M+o4jrOz3aWbsWPa3M/VNC5ydICUU"

    /// What the agent's comment for the key was.
    static let expectedComment = "throwaway fixture key"

    /// The payload that was signed, for rebuilding the same request in a test.
    static let signedPayload = Data("driverpro fixture payload".utf8)

    /// `SSH_AGENT_IDENTITIES_ANSWER` (12) holding one Ed25519 key.
    ///
    /// Shape: the message number, a 4-byte count, then per key an SSH string for the public key blob and
    /// another for the comment.
    static let identitiesAnswer = Data([
        0x0c, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x33, 0x00, 0x00, 0x00, 0x0b, 0x73, 0x73, 0x68,
        0x2d, 0x65, 0x64, 0x32, 0x35, 0x35, 0x31, 0x39, 0x00, 0x00, 0x00, 0x20, 0x5d, 0xb1, 0x53, 0x6d,
        0xc0, 0x0e, 0x08, 0x60, 0xc4, 0xd9, 0x01, 0x04, 0x1f, 0xb9, 0x12, 0x1e, 0x6e, 0xae, 0x0b, 0x4f,
        0x99, 0x0c, 0x16, 0x39, 0x9e, 0x69, 0x28, 0xd7, 0x34, 0x0f, 0x95, 0xa0, 0x00, 0x00, 0x00, 0x15,
        0x74, 0x68, 0x72, 0x6f, 0x77, 0x61, 0x77, 0x61, 0x79, 0x20, 0x66, 0x69, 0x78, 0x74, 0x75, 0x72,
        0x65, 0x20, 0x6b, 0x65, 0x79,
    ])

    /// `SSH_AGENT_IDENTITIES_ANSWER` (12) holding nothing — an agent that is running but empty.
    ///
    /// Built rather than captured, because it is exactly five bytes and there is nothing to get wrong:
    /// the message number and a zero count.
    static let emptyIdentitiesAnswer = Data([0x0c, 0x00, 0x00, 0x00, 0x00])

    /// `SSH_AGENT_SIGN_RESPONSE` (14) for ``signedPayload``.
    ///
    /// The signature is itself an SSH string containing two more: the algorithm name, then 64 bytes of
    /// Ed25519 signature. That nesting is what the NIOSSH adapter has to unpick.
    static let signResponse = Data([
        0x0e, 0x00, 0x00, 0x00, 0x53, 0x00, 0x00, 0x00, 0x0b, 0x73, 0x73, 0x68, 0x2d, 0x65, 0x64, 0x32,
        0x35, 0x35, 0x31, 0x39, 0x00, 0x00, 0x00, 0x40, 0x2d, 0x08, 0x71, 0xc2, 0x31, 0xaf, 0xcd, 0x0e,
        0xf8, 0xb0, 0x5f, 0x51, 0xcb, 0x30, 0x39, 0xfb, 0x01, 0xc8, 0x66, 0xd1, 0xce, 0x68, 0x0f, 0xcb,
        0x92, 0x92, 0xb3, 0x09, 0xee, 0xa5, 0x38, 0x63, 0x55, 0xbd, 0x1e, 0xab, 0x8d, 0x27, 0xcf, 0xa0,
        0x80, 0x23, 0x3c, 0x18, 0xbf, 0x7b, 0xa0, 0xc4, 0x13, 0x27, 0xf2, 0xfd, 0x41, 0x41, 0xcf, 0x5f,
        0x17, 0x61, 0x36, 0xf8, 0xf0, 0x7f, 0x7a, 0x0a,
    ])

    /// `SSH_AGENT_FAILURE` (5), as sent when the agent is asked to sign with a key it does not hold.
    ///
    /// One byte, and no explanation — which is why ``DPCredentials/CredentialError/agent(reason:)`` has to
    /// supply the context itself.
    static let failure = Data([0x05])

    /// The Ed25519 public key blob the agent reported, lifted out of ``identitiesAnswer``.
    static var keyBlob: Data {
        let base64 = publicKeyLine.split(separator: " ")[1]
        return Data(base64Encoded: String(base64))!
    }
}
