//
//  RemotePath.swift
//  DPCore
//

import Foundation

/// An absolute location on a remote file system.
///
/// `RemotePath` is deliberately *not* `URL` and *not* `String`. Both of those invite bugs that this type
/// makes impossible:
///
/// - `URL` percent-encodes, which silently corrupts file names that legitimately contain `%`, `#`, or `?`.
/// - `String` lets `"/a/b"`, `"/a/b/"`, and `"/a//b"` be three different values for one location.
///
/// A `RemotePath` stores its already-normalised path *components*, so those three strings all produce
/// one equal, identically-hashing value. That matters because paths are used as dictionary keys
/// throughout the browser and transfer queue.
///
/// Paths are always absolute; the root is the empty component list. Anything relative must be resolved
/// against a known directory (typically the session's home directory) before it becomes a `RemotePath`.
///
/// ## A note on `..`
/// Normalisation resolves `..` *lexically* — purely by text, without asking the server. On a file system
/// with symbolic links this is not always the same place the server would land on: if `/a/b` is a link to
/// `/x/y`, then `/a/b/..` is `/x` to the server but `/a` to us. This is the same trade-off `URL`,
/// `os.path.normpath`, and most FTP clients make, and it is the right one here — the alternative is a
/// network round trip to interpret every path. Where it matters, resolve links explicitly with
/// ``Session/stat(_:)``.
///
/// ## Swift note — `Sendable`
/// This type is `Sendable`, meaning the compiler has verified it is safe to pass between concurrent
/// tasks. It gets that for free: it is a `struct` holding only `let` properties of `Sendable` types
/// (`Array` and `String`), so there is no shared mutable state to race on. Value semantics do the work.
public struct RemotePath: Hashable, Sendable {

    // MARK: - Storage

    /// The normalised path components, without separators.
    ///
    /// Empty for the root directory. Never contains `""`, `"."`, or `".."`.
    public let components: [String]

    // MARK: - Creating a path

    /// Creates a path from already-normalised components.
    ///
    /// Any `""`, `"."`, or `".."` entries are still resolved, so this is safe to call with raw input.
    ///
    /// - Parameter components: The path components, outermost first.
    public init(components: [String]) {
        self.components = Self.normalise(components)
    }

    /// Creates a path by parsing a POSIX-style path string.
    ///
    /// Leading and trailing slashes, repeated slashes, `.`, and `..` are all normalised away. The path is
    /// treated as absolute whether or not it starts with `/`.
    ///
    /// ```swift
    /// RemotePath("/var/log/../www//index.html").pathString  // "/var/www/index.html"
    /// RemotePath("docs/guide.md").pathString                // "/docs/guide.md"
    /// ```
    ///
    /// - Parameter string: A POSIX path.
    public init(_ string: String) {
        self.init(components: string.split(separator: "/").map(String.init))
    }

    /// The root directory, `/`.
    public static let root = RemotePath(components: [])

    // MARK: - Inspecting a path

    /// `true` when this path is the root directory.
    public var isRoot: Bool { components.isEmpty }

    /// The final path component — the file or directory's own name.
    ///
    /// Returns `"/"` for the root directory, so this is always safe to display.
    public var name: String { components.last ?? "/" }

    /// The directory containing this path, or `nil` if this *is* the root.
    ///
    /// Returning an optional rather than "root is its own parent" is what lets `while let parent = …`
    /// walk up the tree and terminate on its own.
    public var parent: RemotePath? {
        guard !isRoot else { return nil }
        return RemotePath(components: components.dropLast())
    }

    /// Every directory from the root down to this path, inclusive — the breadcrumb trail.
    ///
    /// For `/var/www/html` this is `[/, /var, /var/www, /var/www/html]`.
    public var ancestorsAndSelf: [RemotePath] {
        (0...components.count).map { RemotePath(components: Array(components.prefix($0))) }
    }

    /// The canonical POSIX string for this path, always beginning with `/`.
    ///
    /// The root is `"/"`; every other path has no trailing slash.
    public var pathString: String {
        isRoot ? "/" : "/" + components.joined(separator: "/")
    }

    /// The file extension without its dot, or `""` when there is none.
    ///
    /// A leading dot does not count as an extension separator, so `.bashrc` has no extension — matching
    /// POSIX convention and what users expect to see in the browser.
    public var pathExtension: String {
        guard let dot = name.lastIndex(of: "."), dot != name.startIndex else { return "" }
        return String(name[name.index(after: dot)...])
    }

    /// The name with its extension removed. `"report.tar.gz"` gives `"report.tar"`.
    public var stem: String {
        let ext = pathExtension
        guard !ext.isEmpty else { return name }
        return String(name.dropLast(ext.count + 1))
    }

    /// `true` when the name begins with a dot, the POSIX convention for a hidden file.
    ///
    /// The root is never hidden.
    public var isHidden: Bool { !isRoot && name.hasPrefix(".") }

    // MARK: - Deriving new paths

    /// Returns the path of a child with the given name.
    ///
    /// The name is treated as a single component: any `/` inside it is stripped rather than interpreted
    /// as a separator, so a hostile or malformed server response cannot use this to escape the intended
    /// directory. Use ``appending(path:)`` when you genuinely mean a multi-component path.
    ///
    /// - Parameter component: The child's name.
    public func appending(_ component: String) -> RemotePath {
        let safe = component.replacingOccurrences(of: "/", with: "")
        guard !safe.isEmpty, safe != ".", safe != ".." else { return self }
        return RemotePath(components: components + [safe])
    }

    /// Returns a descendant path by appending a multi-component relative path.
    ///
    /// - Parameter path: A relative path such as `"a/b/c"`.
    public func appending(path: String) -> RemotePath {
        RemotePath(components: components + path.split(separator: "/").map(String.init))
    }

    /// Returns this path with its final component renamed.
    ///
    /// Returns the root unchanged, since the root has no name to change.
    ///
    /// - Parameter newName: The new final component.
    public func renamed(to newName: String) -> RemotePath {
        guard let parent else { return self }
        return parent.appending(newName)
    }

    /// Reports whether `other` lies inside this directory, at any depth.
    ///
    /// A path is not considered an ancestor of itself. Used to stop a recursive move or copy from being
    /// dropped into its own subtree.
    ///
    /// - Parameter other: The candidate descendant.
    public func isAncestor(of other: RemotePath) -> Bool {
        other.components.count > components.count
            && Array(other.components.prefix(components.count)) == components
    }

    /// The components of `other` relative to this directory, or `nil` if `other` is not inside it.
    ///
    /// This is how a recursive transfer works out where a deeply-nested remote file should land inside
    /// the local download folder.
    ///
    /// - Parameter other: A path at or below this one.
    public func relativeComponents(to other: RemotePath) -> [String]? {
        guard other == self || isAncestor(of: other) else { return nil }
        return Array(other.components.dropFirst(components.count))
    }

    // MARK: - Normalisation

    /// Resolves `""`, `"."`, and `".."` out of a component list.
    ///
    /// `..` above the root is discarded rather than escaping it — there is nothing above `/`, and a
    /// server that sends `/../../etc/passwd` is not owed a helpful interpretation.
    private static func normalise(_ raw: [String]) -> [String] {
        var result: [String] = []
        result.reserveCapacity(raw.count)
        for component in raw {
            switch component {
            case "", ".":
                continue
            case "..":
                if !result.isEmpty { result.removeLast() }
            default:
                result.append(component)
            }
        }
        return result
    }
}

// MARK: - Protocol conformances

extension RemotePath: CustomStringConvertible {
    /// The canonical path string, so `print(path)` and string interpolation show `/var/www`.
    public var description: String { pathString }
}

extension RemotePath: Comparable {
    /// Orders paths depth-first and alphabetically, which is a stable order for tests and for display.
    ///
    /// Comparison is case-insensitive so that `Photos` and `photos` sort next to each other rather than
    /// being separated by every lowercase name, matching Finder's behaviour.
    public static func < (lhs: RemotePath, rhs: RemotePath) -> Bool {
        for (l, r) in zip(lhs.components, rhs.components) where l != r {
            return l.localizedStandardCompare(r) == .orderedAscending
        }
        return lhs.components.count < rhs.components.count
    }
}

extension RemotePath: Codable {
    /// Encodes as a single path string rather than an array.
    ///
    /// ## Swift note — custom `Codable`
    /// Synthesised `Codable` would write `{"components":["var","www"]}`. A `singleValueContainer` lets the
    /// type encode as one primitive instead, giving `"/var/www"` — which is what a human reading a saved
    /// bookmark or a queue file wants to see. Decoding runs the string back through the normalising
    /// initialiser, so a hand-edited file cannot introduce an unnormalised path.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        self.init(try container.decode(String.self))
    }

    /// Encodes the path as its canonical string form.
    /// - Parameter encoder: The encoder to write to.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(pathString)
    }
}
