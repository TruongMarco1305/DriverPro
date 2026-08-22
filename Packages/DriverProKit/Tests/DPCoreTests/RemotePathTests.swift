//
//  RemotePathTests.swift
//  DPCoreTests
//

import Foundation
import Testing
@testable import DPCore

/// ## Swift note — Swift Testing
/// These tests use Swift Testing (`import Testing`), not XCTest. The differences worth knowing:
///
/// - `@Test` marks a function as a test; the name is a readable string, not encoded in the identifier.
/// - `#expect(...)` replaces `XCTAssertEqual` and friends. It is a macro, so on failure it can show the
///   actual values of every sub-expression rather than just "assertion failed".
/// - `#require(...)` is `#expect` that stops the test on failure; use `try #require(optional)` to unwrap.
/// - `@Suite` groups tests in a `struct`. A *fresh instance* is created per test, so stored properties
///   are per-test fixtures with no cleanup needed and no shared state between tests.
/// - Tests run in parallel by default, which is why fixtures must not be global mutable state.
@Suite("RemotePath")
struct RemotePathTests {

    // MARK: - Normalisation

    @Test("Equivalent strings normalise to one canonical path", arguments: [
        "/var/www",
        "/var/www/",
        "//var//www",
        "var/www",
        "/var/./www",
        "/var/log/../www",
        "/var/www/x/..",
    ])
    func normalisesEquivalentSpellings(_ input: String) {
        #expect(RemotePath(input).pathString == "/var/www")
    }

    @Test("Root has an empty component list and prints as a single slash")
    func rootIsEmpty() {
        #expect(RemotePath.root.components.isEmpty)
        #expect(RemotePath.root.pathString == "/")
        #expect(RemotePath.root.isRoot)
        #expect(RemotePath("/") == .root)
        #expect(RemotePath("").isRoot)
    }

    @Test("Normalised spellings are equal and hash identically")
    func equalityAndHashing() {
        let a = RemotePath("/a/b/")
        let b = RemotePath("//a//b")
        #expect(a == b)
        // Paths are used as dictionary keys throughout the browser, so equal values must also hash equally.
        #expect(Set([a, b]).count == 1)
    }

    @Test("`..` cannot escape above the root")
    func cannotEscapeRoot() {
        #expect(RemotePath("/../../etc/passwd").pathString == "/etc/passwd")
        #expect(RemotePath("/..").isRoot)
    }

    // MARK: - Components

    @Test("name returns the last component, or a slash at the root")
    func name() {
        #expect(RemotePath("/var/www/index.html").name == "index.html")
        #expect(RemotePath.root.name == "/")
    }

    @Test("parent walks up and terminates at the root")
    func parentTerminates() throws {
        var path = RemotePath("/a/b/c")
        var depth = 0
        while let parent = path.parent {
            path = parent
            depth += 1
        }
        #expect(path.isRoot)
        #expect(depth == 3)
    }

    @Test("ancestorsAndSelf produces the full breadcrumb trail")
    func breadcrumbs() {
        let trail = RemotePath("/var/www").ancestorsAndSelf.map(\.pathString)
        #expect(trail == ["/", "/var", "/var/www"])
    }

    // MARK: - Extensions

    // A single collection of tuples paired with a single tuple parameter. Swift Testing zips *two*
    // collections into two parameters, so a three-way case is expressed as one tuple rather than three
    // separate argument lists.
    @Test("pathExtension and stem split on the last dot", arguments: [
        (path: "/a/report.tar.gz", ext: "gz", stem: "report.tar"),
        (path: "/a/README", ext: "", stem: "README"),
        (path: "/a/.bashrc", ext: "", stem: ".bashrc"),   // a leading dot is not an extension separator
        (path: "/a/archive.", ext: "", stem: "archive.")  // a trailing dot yields no extension
    ])
    func extensionAndStem(_ testCase: (path: String, ext: String, stem: String)) {
        let remote = RemotePath(testCase.path)
        #expect(remote.pathExtension == testCase.ext)
        #expect(remote.stem == testCase.stem)
    }

    @Test("Hidden files are those whose name starts with a dot")
    func hidden() {
        #expect(RemotePath("/home/user/.ssh").isHidden)
        #expect(!RemotePath("/home/user/notes.txt").isHidden)
        #expect(!RemotePath.root.isHidden)
    }

    // MARK: - Deriving paths

    @Test("appending(_:) treats its argument as one component and strips separators")
    func appendingIsSlashSafe() {
        let base = RemotePath("/uploads")
        #expect(base.appending("photo.jpg").pathString == "/uploads/photo.jpg")
        // A server returning a name containing a slash must not be able to redirect us elsewhere:
        // the separators are stripped, leaving one harmless (if ugly) component.
        #expect(base.appending("../../etc/passwd").pathString == "/uploads/....etcpasswd")
        #expect(base.appending("..") == base)
        #expect(base.appending("") == base)
    }

    @Test("appending(path:) does interpret separators")
    func appendingMultipleComponents() {
        #expect(RemotePath("/a").appending(path: "b/c").pathString == "/a/b/c")
    }

    @Test("renamed(to:) replaces only the final component")
    func renaming() {
        #expect(RemotePath("/a/b/old.txt").renamed(to: "new.txt").pathString == "/a/b/new.txt")
        #expect(RemotePath.root.renamed(to: "x").isRoot)
    }

    // MARK: - Containment

    @Test("isAncestor is strict — a path does not contain itself")
    func ancestry() {
        let parent = RemotePath("/a/b")
        #expect(parent.isAncestor(of: RemotePath("/a/b/c")))
        #expect(parent.isAncestor(of: RemotePath("/a/b/c/d")))
        #expect(!parent.isAncestor(of: parent))
        #expect(!parent.isAncestor(of: RemotePath("/a/bb/c")))   // prefix of the name, not of the path
        #expect(!parent.isAncestor(of: RemotePath("/a")))
    }

    @Test("relativeComponents gives the tail used to rebuild a local path")
    func relativeComponents() {
        let root = RemotePath("/srv/data")
        #expect(root.relativeComponents(to: RemotePath("/srv/data/a/b.txt")) == ["a", "b.txt"])
        #expect(root.relativeComponents(to: root) == [])
        #expect(root.relativeComponents(to: RemotePath("/etc")) == nil)
    }

    // MARK: - Codable

    @Test("Encodes as a plain string and survives a round trip")
    func codableRoundTrip() throws {
        let original = RemotePath("/var/www/index.html")
        let data = try JSONEncoder().encode(original)

        // Decoding as a `String` proves the encoded form is one JSON string rather than an object
        // wrapping a component array. Asserting on the raw bytes instead would be brittle: Foundation
        // escapes forward slashes as `\/`, which is legal JSON but an implementation detail we do not
        // want a test to depend on.
        #expect(try JSONDecoder().decode(String.self, from: data) == "/var/www/index.html")

        let decoded = try JSONDecoder().decode(RemotePath.self, from: data)
        #expect(decoded == original)
    }

    @Test("Decoding normalises, so a hand-edited file cannot inject a bad path")
    func decodingNormalises() throws {
        let data = Data(#""/a//b/../c/""#.utf8)
        let decoded = try JSONDecoder().decode(RemotePath.self, from: data)
        #expect(decoded.pathString == "/a/c")
    }

    // MARK: - Ordering

    @Test("Ordering is alphabetical, then shallower before deeper")
    func sorting() {
        #expect(RemotePath("/a") < RemotePath("/b"))
        // A directory sorts before its own contents.
        #expect(RemotePath("/a") < RemotePath("/a/z"))
        // The first differing component decides, regardless of depth further along.
        #expect(RemotePath("/a/z") < RemotePath("/b/a"))

        let sorted = [RemotePath("/b"), RemotePath("/a/z"), RemotePath("/a")]
            .sorted()
            .map(\.pathString)
        #expect(sorted == ["/a", "/a/z", "/b"])
    }
}
