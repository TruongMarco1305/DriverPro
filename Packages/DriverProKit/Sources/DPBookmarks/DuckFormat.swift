//
//  DuckFormat.swift
//  DPBookmarks
//

import DPCore
import Foundation

/// What a `.duck` file turned out to hold.
///
/// Three outcomes rather than an optional, because "we cannot speak this protocol yet" and "this is not
/// a bookmark" deserve different things said about them.
public enum DuckDecoding: Sendable, Equatable {
    /// A bookmark DriverPro can use.
    case bookmark(RemoteHost)
    /// A real protocol, just not one this build supports. Skipped, and reported.
    case unsupported(ProtocolIdentifier)
    /// Not a bookmark at all: unparseable, or missing the one key that is mandatory.
    case unreadable(reason: String)
}

/// Cyberduck's `.duck` bookmark file.
///
/// One XML property list per bookmark, root a single dictionary. Verified against Cyberduck's own
/// serialiser rather than inferred — `Host.serialize` and `HostDictionary.deserialize`.
///
/// **Every scalar is a plist string, `Port` included.** Cyberduck writes
/// `setStringForKey(String.valueOf(getPort()), "Port")` and reads it back with `Integer.parseInt`, so a
/// file written with `<integer>22</integer>` loads with its port silently ignored. See
/// `docs/decisions/011-duck-interchange.md`.
public enum DuckFormat {

    /// The file extension, without the dot.
    public static let fileExtension = "duck"

    /// The key holding everything Cyberduck wrote that DriverPro has no field for.
    ///
    /// Base64 of a binary plist, so an import followed by an export gives back the timezone, labels and
    /// folder settings the file arrived with instead of quietly dropping them. One opaque value because
    /// ``RemoteHost/properties`` is `[String: String]` and much of what Cyberduck writes is nested.
    public static let preservedKey = "duck.unmapped"

    /// Keys DriverPro understands, and therefore does not stash in ``preservedKey``.
    ///
    /// The private key entries are deliberately *not* here. DriverPro models the path but not the
    /// `Bookmark` alias beside it — the security-scoped handle a sandboxed Cyberduck needs to reopen the
    /// file — so the whole dictionary is preserved and only its `Path` is overwritten on the way out.
    /// Mapping it would silently strip that alias and break the key for them.
    private static let mappedKeys: Set<String> = [
        "Protocol", "Hostname", "Port", "Username", "Path", "Nickname", "UUID", "Comment",
        driverProDefaultPathKey
    ]

    /// Where a WebDAV bookmark's *browsing* start point goes, since `Path` is carrying its DAV root.
    ///
    /// Cyberduck has one path where DriverPro has two, so an export has to choose which one `Path`
    /// holds — see ``paths(in:for:)``. This carries the other, so a DriverPro-to-DriverPro round trip
    /// loses nothing. Cyberduck ignores keys it does not know, so writing it costs them nothing.
    static let driverProDefaultPathKey = "DriverPro Default Path"

    /// Reads the one or two paths a bookmark has, according to what its protocol means by `Path`.
    ///
    /// **The mapping problem.** Cyberduck models a bookmark as a URL, so `Path` is simply where
    /// browsing begins. DriverPro splits that in two for WebDAV: ``RemoteHost/webdavBasePathKey`` is the
    /// DAV root — the prefix every request is built on, `/remote.php/dav/files/duck` for Nextcloud — and
    /// `defaultPath` is the folder to open inside it. Cyberduck has nowhere to put the second.
    ///
    /// **So `Path` carries the DAV root**, because it is the half without which the bookmark does not
    /// work at all: lose the default path and you start at the account root, lose the DAV root and
    /// nothing resolves. It also means a Nextcloud bookmark exported from Cyberduck — whose `Path` *is*
    /// its DAV root — imports correctly, which is the whole point of reading someone else's format.
    ///
    /// Every other protocol is unchanged: `Path` is the default path, as it always was.
    ///
    /// - Parameters:
    ///   - dictionary: The bookmark as read from the file.
    ///   - protocolIdentifier: What the bookmark speaks, which decides what `Path` means.
    /// - Returns: The default path, and any properties the paths imply.
    private static func paths(
        in dictionary: [String: Any],
        for protocolIdentifier: ProtocolIdentifier
    ) -> (defaultPath: RemotePath?, properties: [String: String]) {
        let path = nonEmpty(dictionary["Path"])

        guard protocolIdentifier == .webdav else {
            return (path.map { RemotePath($0) }, [:])
        }

        var properties: [String: String] = [:]
        if let path { properties[RemoteHost.webdavBasePathKey] = path }
        let ours = nonEmpty(dictionary[driverProDefaultPathKey]).map { RemotePath($0) }
        return (ours, properties)
    }

    // MARK: - Protocol identifiers

    /// Cyberduck's identifier for each protocol DriverPro knows, as written on export.
    ///
    /// `sftp`, `davs` and `s3` are taken from Cyberduck's source; `ftp` is confirmed by a real file.
    /// WebDAV exports as the secure spelling — a plain-HTTP bookmark is not what anyone means by
    /// "export this connection".
    private static let identifierForProtocol: [ProtocolIdentifier: String] = [
        .sftp: "sftp",
        .webdav: "davs",
        .s3: "s3",
        .ftp: "ftp"
    ]

    /// Every identifier accepted on import, including the ones with two spellings.
    private static let protocolForIdentifier: [String: ProtocolIdentifier] = [
        "sftp": .sftp,
        "dav": .webdav, "davs": .webdav,
        "s3": .s3,
        "ftp": .ftp, "ftps": .ftp
    ]

    // MARK: - Decoding

    /// Reads a `.duck` file.
    ///
    /// Never throws: a bad file is one of the failure cases, because an import runs over a folder and
    /// one unreadable file must not abandon the rest.
    ///
    /// - Parameters:
    ///   - data: The file's contents.
    ///   - supported: Protocols this build can actually connect with.
    ///   - defaultPort: Port to use when the file gives none, or gives one that is not a number.
    /// - Returns: What the file held.
    public static func decode(
        _ data: Data,
        supported: Set<ProtocolIdentifier>,
        defaultPort: Int = 22
    ) -> DuckDecoding {
        guard let parsed = try? PropertyListSerialization.propertyList(from: data, format: nil),
              let dictionary = parsed as? [String: Any] else {
            return .unreadable(reason: "not a property list")
        }

        // The one mandatory key. Cyberduck refuses the file without it, and so do we — a connection
        // profile happens to share this shape, and importing one as a bookmark would be nonsense.
        guard let identifier = dictionary["Protocol"] as? String else {
            return .unreadable(reason: "no Protocol key, so this is not a bookmark")
        }
        guard let protocolIdentifier = protocolForIdentifier[identifier] else {
            return .unreadable(reason: "unknown protocol “\(identifier)”")
        }
        guard supported.contains(protocolIdentifier) else {
            return .unsupported(protocolIdentifier)
        }
        guard let hostname = nonEmpty(dictionary["Hostname"]) else {
            return .unreadable(reason: "no Hostname")
        }

        // A port that will not parse falls back to the default rather than failing the file: the rest
        // of the bookmark is still worth having, and a wrong port is visible and fixable.
        let port = (dictionary["Port"] as? String).flatMap(Int.init) ?? defaultPort

        let (defaultPath, extraProperties) = paths(in: dictionary, for: protocolIdentifier)

        var host = RemoteHost(
            id: (dictionary["UUID"] as? String).flatMap(UUID.init) ?? UUID(),
            protocolIdentifier: protocolIdentifier,
            hostname: hostname,
            port: port,
            username: nonEmpty(dictionary["Username"]),
            defaultPath: defaultPath,
            nickname: nonEmpty(dictionary["Nickname"]),
            comment: nonEmpty(dictionary["Comment"]),
            properties: preserved(from: dictionary).merging(extraProperties) { _, new in new }
        )

        // A bookmark naming a key file means "log in with this key", so both halves of the preference
        // are set. A path that no longer exists needs no special case: the preference's getter degrades
        // to a password prompt, which is recoverable.
        if let keyPath = privateKeyPath(in: dictionary) {
            host.authenticationPreference = .privateKey(path: keyPath)
        }
        return .bookmark(host)
    }

    /// The private key path, from either spelling.
    ///
    /// Cyberduck writes `Private Key File Dictionary` — a serialised `Local`, whose `Path` is
    /// *abbreviated*, so it arrives as `~/.ssh/id_ed25519` and has to be expanded. The bare
    /// `Private Key File` string is the legacy form and still appears in older files.
    private static func privateKeyPath(in dictionary: [String: Any]) -> String? {
        let path = (dictionary["Private Key File Dictionary"] as? [String: Any])
            .flatMap { nonEmpty($0["Path"]) }
            ?? nonEmpty(dictionary["Private Key File"])

        return path.map { NSString(string: $0).expandingTildeInPath }
    }

    // MARK: - Encoding

    /// Writes a bookmark as a `.duck` file.
    ///
    /// Anything the bookmark arrived with and DriverPro does not model is written back out, so a round
    /// trip through DriverPro does not strip someone's file.
    ///
    /// - Parameter host: The bookmark to write.
    /// - Returns: XML property list data.
    /// - Throws: If the property list cannot be serialised.
    public static func encode(_ host: RemoteHost) throws -> Data {
        var dictionary = restored(from: host.properties)

        dictionary["Protocol"] = identifierForProtocol[host.protocolIdentifier]
            ?? host.protocolIdentifier.rawValue
        dictionary["Hostname"] = host.hostname
        // A string, not a number. This is the trap the whole format hinges on.
        dictionary["Port"] = String(host.port)
        dictionary["UUID"] = host.id.uuidString

        // Set only when there is something to set: Cyberduck treats a missing key and an empty string
        // differently, and an empty Nickname shows as a blank row in its sidebar.
        setOrRemove(&dictionary, "Username", host.username)
        setOrRemove(&dictionary, "Nickname", host.nickname)
        setOrRemove(&dictionary, "Comment", host.comment)

        // Which path goes in `Path` depends on the protocol; see `paths(in:for:)` for why WebDAV's is
        // its DAV root rather than its default path.
        if host.protocolIdentifier == .webdav {
            setOrRemove(&dictionary, "Path", host.properties[RemoteHost.webdavBasePathKey])
            setOrRemove(&dictionary, driverProDefaultPathKey, host.defaultPath?.pathString)
        } else {
            setOrRemove(&dictionary, "Path", host.defaultPath?.pathString)
        }

        // Written in the form Cyberduck writes, with the home directory abbreviated as it does. The
        // legacy key goes too: older Cyberduck builds read only that one.
        if let keyPath = host.authenticationPreference.privateKeyPath, !keyPath.isEmpty {
            let abbreviated = NSString(string: keyPath).abbreviatingWithTildeInPath
            var local = dictionary["Private Key File Dictionary"] as? [String: Any] ?? [:]
            local["Path"] = abbreviated
            dictionary["Private Key File Dictionary"] = local
            dictionary["Private Key File"] = abbreviated
        } else {
            dictionary.removeValue(forKey: "Private Key File Dictionary")
            dictionary.removeValue(forKey: "Private Key File")
        }

        return try PropertyListSerialization.data(
            fromPropertyList: dictionary, format: .xml, options: 0
        )
    }

    /// What to call the file for a bookmark, matching how Cyberduck names its own.
    ///
    /// - Parameter host: The bookmark being written.
    /// - Returns: A file name, extension included, safe to write.
    public static func fileName(for host: RemoteHost) -> String {
        // `/` and `:` are what Finder and the file system object to; the rest of a display name is fine.
        let safe = host.displayName
            .components(separatedBy: CharacterSet(charactersIn: "/:"))
            .joined(separator: "-")
            .trimmingCharacters(in: .whitespaces)

        return "\(safe.isEmpty ? host.hostname : safe).\(fileExtension)"
    }

    // MARK: - Preserving what we do not model

    /// Packs every unmapped key into one base64 binary plist.
    private static func preserved(from dictionary: [String: Any]) -> [String: String] {
        let unmapped = dictionary.filter { !mappedKeys.contains($0.key) }
        guard !unmapped.isEmpty,
              let data = try? PropertyListSerialization.data(
                  fromPropertyList: unmapped, format: .binary, options: 0)
        else { return [:] }

        return [preservedKey: data.base64EncodedString()]
    }

    /// Unpacks what ``preserved(from:)`` stored. Anything unreadable is dropped rather than thrown on.
    private static func restored(from properties: [String: String]) -> [String: Any] {
        guard let encoded = properties[preservedKey],
              let data = Data(base64Encoded: encoded),
              let parsed = try? PropertyListSerialization.propertyList(from: data, format: nil),
              let dictionary = parsed as? [String: Any]
        else { return [:] }

        return dictionary
    }

    // MARK: - Helpers

    /// A trimmed string, or `nil` when there is nothing there.
    private static func nonEmpty(_ value: Any?) -> String? {
        guard let text = value as? String else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func setOrRemove(_ dictionary: inout [String: Any], _ key: String, _ value: String?) {
        if let value, !value.isEmpty {
            dictionary[key] = value
        } else {
            dictionary.removeValue(forKey: key)
        }
    }
}
