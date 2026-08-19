//
//  SSHAgentWire.swift
//  DPCredentials
//

import Foundation

/// Encodes and decodes the ssh-agent protocol. Bytes in, values out — no I/O at all.
///
/// Separated from the socket so the format can be tested against bytes captured from a real agent. That
/// distinction matters more than it looks: a test that round-trips our encoder through our decoder proves
/// only that they agree with each other, which they would even if both were wrong. Fixtures taken off the
/// wire are the only thing that proves agreement with OpenSSH.
///
/// The format is small. Every message is a 4-byte big-endian length followed by that many bytes, whose
/// first byte is the message number. Inside, an "SSH string" is again a 4-byte big-endian length followed
/// by that many bytes — used for both text and binary, which is why a key blob and a comment look
/// identical on the wire.
///
/// Reference: OpenSSH's `PROTOCOL.agent`.
enum SSHAgentWire {

    // MARK: - Message numbers

    /// The message numbers this client uses or expects to receive.
    enum Message: UInt8 {
        /// The agent refused, or holds nothing that applies.
        case failure = 5
        /// The agent complied, for requests that return no data.
        case success = 6
        /// "List what you hold." Sent by us.
        case requestIdentities = 11
        /// The list of identities. Received.
        case identitiesAnswer = 12
        /// "Sign this with that key." Sent by us.
        case signRequest = 13
        /// The signature. Received.
        case signResponse = 14
    }

    // MARK: - Signature flags

    /// Ask for an `rsa-sha2-256` signature rather than SHA-1.
    static let rsaSHA2_256: UInt32 = 2
    /// Ask for an `rsa-sha2-512` signature rather than SHA-1.
    static let rsaSHA2_512: UInt32 = 4

    // MARK: - Requests

    /// A complete, length-prefixed `REQUEST_IDENTITIES` message.
    static func requestIdentities() -> Data {
        framed(Data([Message.requestIdentities.rawValue]))
    }

    /// A complete, length-prefixed `SIGN_REQUEST` message.
    ///
    /// - Parameters:
    ///   - keyBlob: The public key blob identifying which key to sign with, exactly as the agent
    ///     reported it. The agent matches on these bytes, so they must not be re-encoded.
    ///   - data: What to sign.
    ///   - flags: Signature options, such as ``rsaSHA2_512``. Zero for the algorithm's default.
    static func signRequest(keyBlob: Data, data: Data, flags: UInt32) -> Data {
        var payload = Data([Message.signRequest.rawValue])
        payload.appendSSHString(keyBlob)
        payload.appendSSHString(data)
        payload.appendUInt32(flags)
        return framed(payload)
    }

    /// Wraps a payload in the 4-byte big-endian length every agent message carries.
    static func framed(_ payload: Data) -> Data {
        var message = Data()
        message.appendUInt32(UInt32(payload.count))
        message.append(payload)
        return message
    }

    // MARK: - Responses

    /// Parses an `IDENTITIES_ANSWER` payload.
    ///
    /// - Parameter payload: One unframed message: the message number, then its contents.
    /// - Returns: The identities, in the order the agent listed them — which is `ssh-add` order, and is
    ///   the order they should be offered in.
    /// - Throws: ``CredentialError/agent(reason:)`` if the agent refused or the bytes do not parse.
    static func identities(from payload: Data) throws -> [SSHAgentIdentity] {
        var reader = ByteReader(payload)
        try expect(.identitiesAnswer, in: &reader, whileDoing: "list its keys")

        guard let count = reader.readUInt32(), count <= 1_024 else {
            // A sane cap. A length field is attacker-influenced data even from a local socket, and
            // trusting it would mean allocating whatever it says.
            throw CredentialError.agent(reason: "the agent reported an implausible number of keys")
        }

        var identities: [SSHAgentIdentity] = []
        for _ in 0..<count {
            guard let keyBlob = reader.readSSHString(), let comment = reader.readSSHString() else {
                throw CredentialError.agent(reason: "the agent's key list ended early")
            }
            identities.append(SSHAgentIdentity(
                keyBlob: keyBlob,
                comment: String(data: comment, encoding: .utf8) ?? ""
            ))
        }
        return identities
    }

    /// Parses a `SIGN_RESPONSE` payload.
    ///
    /// - Parameter payload: One unframed message.
    /// - Returns: The signature blob, which is itself an algorithm name followed by the signature body.
    /// - Throws: ``CredentialError/agent(reason:)`` if the agent refused or the bytes do not parse.
    static func signature(from payload: Data) throws -> Data {
        var reader = ByteReader(payload)
        try expect(.signResponse, in: &reader, whileDoing: "sign")

        guard let signature = reader.readSSHString() else {
            throw CredentialError.agent(reason: "the agent's signature was truncated")
        }
        return signature
    }

    /// Checks the message number, turning an explicit `FAILURE` into a readable error.
    ///
    /// `FAILURE` is the common, expected disappointment — a locked agent, or a key the agent no longer
    /// holds — so it earns a message of its own rather than being lumped in with a parse error.
    private static func expect(
        _ expected: Message,
        in reader: inout ByteReader,
        whileDoing action: String
    ) throws {
        guard let number = reader.readByte() else {
            throw CredentialError.agent(reason: "the agent sent an empty reply")
        }
        if number == expected.rawValue { return }
        if number == Message.failure.rawValue {
            throw CredentialError.agent(reason: "the agent refused to \(action)")
        }
        throw CredentialError.agent(reason: "the agent sent an unexpected reply (\(number))")
    }
}

// MARK: - Reading

/// Reads big-endian integers and SSH strings, refusing to read past the end.
///
/// Every read returns an optional rather than trapping. That is the whole point: the bytes come from
/// outside the process, so "the length field says 4 GB but there are nine bytes left" is input to be
/// rejected, not a programming error to crash on.
struct ByteReader {

    private let bytes: Data
    private var offset: Int

    init(_ bytes: Data) {
        self.bytes = bytes
        self.offset = bytes.startIndex
    }

    /// Bytes not yet read.
    var remaining: Int { bytes.endIndex - offset }

    /// Reads one byte.
    mutating func readByte() -> UInt8? {
        guard remaining >= 1 else { return nil }
        defer { offset += 1 }
        return bytes[offset]
    }

    /// Reads a 4-byte big-endian unsigned integer.
    mutating func readUInt32() -> UInt32? {
        guard remaining >= 4 else { return nil }
        let value = bytes[offset..<offset + 4].reduce(into: UInt32(0)) { $0 = ($0 << 8) | UInt32($1) }
        offset += 4
        return value
    }

    /// Reads a length-prefixed byte string.
    mutating func readSSHString() -> Data? {
        let start = offset
        guard let length = readUInt32() else { return nil }
        guard remaining >= Int(length) else {
            offset = start          // leave the reader where it was, so a caller can report position
            return nil
        }
        defer { offset += Int(length) }
        return Data(bytes[offset..<offset + Int(length)])
    }
}

// MARK: - Writing

extension Data {

    /// Appends a 4-byte big-endian unsigned integer.
    mutating func appendUInt32(_ value: UInt32) {
        append(contentsOf: [
            UInt8(truncatingIfNeeded: value >> 24),
            UInt8(truncatingIfNeeded: value >> 16),
            UInt8(truncatingIfNeeded: value >> 8),
            UInt8(truncatingIfNeeded: value)
        ])
    }

    /// Appends a length-prefixed byte string.
    mutating func appendSSHString(_ value: Data) {
        appendUInt32(UInt32(value.count))
        append(value)
    }
}
