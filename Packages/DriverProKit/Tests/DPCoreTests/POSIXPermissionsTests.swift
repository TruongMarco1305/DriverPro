//
//  POSIXPermissionsTests.swift
//  DPCoreTests
//

import Testing
@testable import DPCore

@Suite("POSIXPermissions")
struct POSIXPermissionsTests {

    @Test("Octal modes render as ls-style symbolic strings", arguments: [
        (mode: UInt16(0o755), symbolic: "rwxr-xr-x", octal: "755"),
        (mode: UInt16(0o644), symbolic: "rw-r--r--", octal: "644"),
        (mode: UInt16(0o600), symbolic: "rw-------", octal: "600"),
        (mode: UInt16(0o777), symbolic: "rwxrwxrwx", octal: "777"),
        (mode: UInt16(0o000), symbolic: "---------", octal: "000")
    ])
    func symbolicRendering(_ testCase: (mode: UInt16, symbolic: String, octal: String)) {
        let permissions = POSIXPermissions(rawValue: testCase.mode)
        #expect(permissions.symbolicString == testCase.symbolic)
        #expect(permissions.octalString == testCase.octal)
    }

    @Test("Access classes decode from the right bit triples")
    func accessClasses() {
        let permissions = POSIXPermissions(rawValue: 0o750)
        #expect(permissions.owner == [.read, .write, .execute])
        #expect(permissions.group == [.read, .execute])
        #expect(permissions.other == [])
        #expect(!permissions.other.contains(.read))
    }

    @Test("Building from access classes matches the equivalent octal mode")
    func compositionRoundTrip() {
        let built = POSIXPermissions(owner: [.read, .write, .execute], group: [.read, .execute], other: [.read, .execute])
        #expect(built == POSIXPermissions(rawValue: 0o755))
        #expect(built.symbolicString == "rwxr-xr-x")
    }

    // MARK: - Special bits

    @Test("Sticky, setuid and setgid bits render the way ls renders them")
    func specialBits() {
        // /tmp: 1777 — sticky set, and `other` has execute, so the last character is a lowercase t.
        let tmp = POSIXPermissions(rawValue: 0o1777)
        #expect(tmp.isSticky)
        #expect(tmp.symbolicString == "rwxrwxrwt")
        #expect(tmp.octalString == "1777")

        // Sticky without execute gives an uppercase T — the flag is set but nobody can traverse.
        #expect(POSIXPermissions(rawValue: 0o1666).symbolicString == "rw-rw-rwT")

        // setuid with owner execute: lowercase s in the owner triple.
        let setuid = POSIXPermissions(rawValue: 0o4755)
        #expect(setuid.isSetUID)
        #expect(setuid.symbolicString == "rwsr-xr-x")

        // setgid with group execute: lowercase s in the group triple.
        #expect(POSIXPermissions(rawValue: 0o2775).symbolicString == "rwxrwsr-x")
    }

    @Test("File-type bits above the low twelve are discarded")
    func masksFileTypeBits() {
        // 0o100644 is a regular file with mode 644, as returned by stat(2). Only the mode survives.
        #expect(POSIXPermissions(rawValue: 0o100644 & 0xFFFF).octalString == "644")
    }

    // MARK: - Parsing

    @Test("Valid octal strings parse", arguments: ["755", "0755", "644", "1777", "0"])
    func parsesValidOctal(_ input: String) throws {
        let parsed = try #require(POSIXPermissions(octalString: input))
        #expect(parsed.rawValue == UInt16(input, radix: 8)! & 0o7777)
    }

    @Test("Invalid strings are rejected rather than silently coerced", arguments: ["", "abc", "888", "12345", "-1"])
    func rejectsInvalidOctal(_ input: String) {
        #expect(POSIXPermissions(octalString: input) == nil)
    }

    @Test("Whitespace around a typed value is tolerated")
    func trimsWhitespace() {
        #expect(POSIXPermissions(octalString: "  755 ") == POSIXPermissions(rawValue: 0o755))
    }
}
