//
//  S3Client.swift
//  DPProtocolS3
//

import AsyncHTTPClient
import DPCore
import Foundation
import SotoCore
import SotoS3

/// Soto's `AWSClient` and `S3` service, built from a bookmark and shut down on demand.
///
/// One type owns the whole Soto surface so that everything the SDK imposes — construction, addressing,
/// and above all *shutdown* — lives in one place rather than being spread through the session.
///
/// ## Why shutdown is not optional
/// `AWSClient.deinit` asserts that the client was shut down first. In a debug build a missed
/// ``shutdown()`` therefore **traps** rather than leaking; in release the assert is compiled out and it
/// leaks the credential provider's task instead. Neither is acceptable, so `S3Session.disconnect()`
/// calls this and `SessionPool` is what guarantees `disconnect` runs.
///
/// The HTTP client is deliberately *not* ours: Soto defaults to `HTTPClient.shared`, so the expensive
/// part — the event loop group and the connection pool — is shared across every session, and what one
/// `AWSClient` costs is close to nothing. That is what makes one client per session affordable.
struct S3Client: Sendable {

    /// The Soto client. Owns credentials and the retry policy.
    let aws: AWSClient

    /// The S3 service bound to that client, a region and an endpoint.
    let s3: S3

    /// Builds a client for a bookmark.
    ///
    /// - Parameters:
    ///   - host: The bookmark, whose hostname and port are the endpoint and whose `properties` carry the
    ///     region and addressing style.
    ///   - accessKeyID: The access key id — `RemoteHost.username` by another name.
    ///   - secretAccessKey: The secret access key.
    init(host: RemoteHost, accessKeyID: String, secretAccessKey: String) {
        self.aws = AWSClient(
            credentialProvider: .static(accessKeyId: accessKeyID, secretAccessKey: secretAccessKey),
            httpClient: Self.httpClient
        )

        var options: AWSServiceConfig.Options = []
        // Soto chooses path-style addressing whenever a custom endpoint is set, which is what MinIO,
        // LocalStack and most self-hosted servers need. Virtual-host addressing — `bucket.host` — is
        // what Amazon prefers and what some providers require, so it stays available as a setting.
        if host.properties[Self.pathStyleKey] == "false" {
            options.insert(.s3ForceVirtualHost)
        }

        self.s3 = S3(
            client: aws,
            region: Region(rawValue: host.properties[Self.regionKey] ?? Self.defaultRegion),
            endpoint: Self.endpoint(for: host)
        )
    }

    /// Releases the client. Safe to call more than once.
    ///
    /// Swallows the error deliberately: `shutdown()` throws only `alreadyShutdown`, and a second call is
    /// exactly what a `defer` in a failed `connect` produces. There is nothing a caller could do about
    /// it, and `Session.disconnect` promises not to throw.
    func shutdown() async {
        try? await aws.shutdown()
    }

    // MARK: - The transport

    /// The HTTP client every S3 session shares.
    ///
    /// **Not `HTTPClient.shared`**, which is what Soto would use by default, because that singleton is
    /// configured to *"match the platform's default/prevalent browser as closely as possible"* — and a
    /// file transfer program is not a browser. Its `decompression: .enabled(limit: .ratio(25))` is the
    /// part that bites, in two different ways:
    ///
    /// 1. **It breaks large listings.** Enabling decompression makes the client advertise
    ///    `Accept-Encoding: gzip`, so MinIO gzips the `ListObjectsV2` XML — which, being a thousand
    ///    near-identical keys, compresses far better than 25:1. The response is then refused with
    ///    `NIOHTTPDecompression.DecompressionError.limit`, and a bucket is unbrowsable for no reason a
    ///    user could ever guess at.
    /// 2. **It would eventually corrupt a download.** `Content-Encoding` on an S3 object is metadata the
    ///    *uploader* chose; the object's bytes are the compressed ones. A client that transparently
    ///    inflates them writes a file that does not match what the server stores.
    ///
    /// This is the same finding as WebDAV's `withoutBrowserBehaviour`, one layer down and in a different
    /// library: the conveniences an HTTP client provides for browsing the web are wrong for moving
    /// files, and both of them are on by default.
    ///
    /// ## Why it is never shut down
    /// It lives for the life of the process, exactly as `HTTPClient.shared` does, so the connection pool
    /// and event loop group are shared across every session rather than rebuilt per connection. That is
    /// what makes one `AWSClient` per session cheap — the `AWSClient` then owns only its credential
    /// provider, which is what ``shutdown()`` releases.
    static let httpClient: HTTPClient = {
        var configuration = HTTPClient.Configuration.singletonConfiguration
        configuration.decompression = .disabled
        return HTTPClient(eventLoopGroupProvider: .singleton, configuration: configuration)
    }()

    // MARK: - Bookmark settings

    /// The `properties` key holding the region, such as `eu-west-1`.
    static let regionKey = "s3.region"

    /// The `properties` key that turns path-style addressing off in favour of `bucket.host`.
    static let pathStyleKey = "s3.pathStyle"

    /// The `properties` key that allows plain HTTP. Absent means HTTPS, as it does for WebDAV.
    static let allowsInsecureKey = "s3.allowsInsecureHTTP"

    /// The region assumed when a bookmark does not name one.
    ///
    /// `us-east-1` rather than something neutral because it is S3's own default: signing requires *a*
    /// region, MinIO and LocalStack ignore which, and Cloudflare R2 aliases it to `auto`.
    static let defaultRegion = "us-east-1"

    /// The endpoint URL a bookmark describes.
    ///
    /// Always explicit, even for Amazon. The bookmark already carries a hostname and a port, and
    /// deriving the endpoint from them keeps every provider — Amazon included — on one code path.
    ///
    /// - Parameter host: The bookmark.
    /// - Returns: An absolute endpoint, such as `https://s3.eu-west-1.amazonaws.com`.
    static func endpoint(for host: RemoteHost) -> String {
        let scheme = host.properties[allowsInsecureKey] == "true" ? "http" : "https"
        let isDefaultPort = (scheme == "https" && host.port == 443) || (scheme == "http" && host.port == 80)
        return isDefaultPort
            ? "\(scheme)://\(host.hostname)"
            : "\(scheme)://\(host.hostname):\(host.port)"
    }
}
