//
//  WebDAVPaths.swift
//  DriverProKit
//
//  Target responsibility
//  ────────────────────
//  DPProtocolWebDAV speaks WebDAV over HTTP: PROPFIND, MKCOL, MOVE, GET, PUT. It implements `Session`
//  and nothing else knows it exists except the composition root.
//
//  It may import Foundation and DPCore. It may NOT import SwiftUI, AppKit, or any other DPProtocol*
//  target. Foundation's URLSession and XMLParser are the whole transport — no dependency is added.
//

import DPCore
import Foundation

/// Turns `RemotePath` into a URL on a server, and back.
///
/// The one idea worth understanding about this backend: **a path is not a URL, and the difference is
/// configuration.** A plain WebDAV server serves its files at `/`; Nextcloud serves them at
/// `/remote.php/dav/files/<user>/`. That prefix lives in the bookmark rather than in a branch here, so
/// Nextcloud is a *setting* rather than a second code path — and S3's bucket prefix should work the
/// same way in M4.
///
/// A value type rather than an actor: it holds three immutable things and does arithmetic on strings.
struct WebDAVPaths: Sendable, Hashable {

    /// Scheme, host and port — everything before the path.
    let origin: URL

    /// What the server puts in front of every path, with no trailing slash. Empty for a plain server.
    let basePath: String

    /// Builds a mapping for a connection.
    ///
    /// - Parameters:
    ///   - host: The bookmark. Its ``RemoteHost/port`` is used as given.
    ///   - basePath: The server's DAV root, such as `/remote.php/dav/files/duck`. Leading and trailing
    ///     slashes are optional; both spellings behave the same.
    ///   - isSecure: Whether to speak HTTPS. Plain HTTP exists for test servers.
    /// - Returns: `nil` when the host does not produce a usable URL.
    init?(host: RemoteHost, basePath: String = "", isSecure: Bool = true) {
        let scheme = isSecure ? "https" : "http"

        var components = URLComponents()
        components.scheme = scheme
        components.host = host.hostname
        // Omitted when it is the scheme's own default, so the URL reads `https://host/` rather than
        // `https://host:443/`. Both are legal; only one is what a server writes in its logs, puts in a
        // redirect, or compares an `href` against.
        if host.port != Self.defaultPort(forScheme: scheme) {
            components.port = host.port
        }

        guard let origin = components.url else { return nil }
        self.origin = origin
        self.basePath = Self.normalise(basePath)
    }

    /// The port a scheme implies, and therefore need not be written.
    private static func defaultPort(forScheme scheme: String) -> Int {
        scheme == "https" ? 443 : 80
    }

    /// Strips the slashes at both ends, so `/dav/`, `dav` and `/dav` are one value.
    private static func normalise(_ path: String) -> String {
        let trimmed = path.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        return trimmed.isEmpty ? "" : "/\(trimmed)"
    }

    // MARK: - Out

    /// The URL to send a request to.
    ///
    /// - Parameters:
    ///   - path: Where on the server, as the rest of DriverPro sees it.
    ///   - isDirectory: Whether to end the URL in a slash. WebDAV servers are entitled to redirect a
    ///     collection request that lacks one, and a redirect loses the method — a `PROPFIND` becomes a
    ///     `GET` and the response is a web page rather than XML.
    /// - Returns: An absolute URL.
    func url(for path: RemotePath, isDirectory: Bool = false) -> URL {
        // Percent-encoded per component, so a `/` inside a name cannot become a path separator and a
        // `#` cannot start a fragment. `.urlPathAllowed` keeps `/` legal, which is why each component
        // is encoded on its own rather than the joined string.
        let encoded = path.components
            .map { $0.addingPercentEncoding(withAllowedCharacters: .webdavPathComponent) ?? $0 }
            .joined(separator: "/")

        var absolute = basePath
        if !encoded.isEmpty { absolute += "/\(encoded)" }
        if isDirectory { absolute += "/" }
        if absolute.isEmpty { absolute = "/" }

        return URL(string: absolute, relativeTo: origin)?.absoluteURL
            ?? origin.appending(path: path.pathString)
    }

    // MARK: - Back

    /// The path an `href` from a multi-status response refers to.
    ///
    /// The server chooses what to put here: some send an absolute URL, some send just the path, and
    /// what comes back is percent-encoded whatever DriverPro sent. Both forms are handled, the base
    /// prefix is stripped, and a trailing slash — the server's way of saying "collection" — is dropped
    /// because ``RemoteItem/kind`` carries that instead.
    ///
    /// - Parameter href: The `<D:href>` value, verbatim.
    /// - Returns: The path, or `nil` if it does not belong to this server's DAV root.
    func path(fromHref href: String) -> RemotePath? {
        // An absolute href brings a scheme and host; take only the path. A relative one is already it.
        let raw = URLComponents(string: href)?.percentEncodedPath ?? href
        guard let decoded = raw.removingPercentEncoding else { return nil }

        var remainder = decoded
        if !basePath.isEmpty {
            guard remainder.hasPrefix(basePath) else { return nil }
            remainder.removeFirst(basePath.count)
        }
        return RemotePath(remainder)
    }
}

extension CharacterSet {

    /// What may appear unencoded in one path component.
    ///
    /// `.urlPathAllowed` minus the separator: a file genuinely named `a/b` is not two directories, and
    /// letting the slash through would silently make it so. `+` is excluded because some servers decode
    /// it as a space.
    static let webdavPathComponent: CharacterSet = {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/+")
        return allowed
    }()
}
