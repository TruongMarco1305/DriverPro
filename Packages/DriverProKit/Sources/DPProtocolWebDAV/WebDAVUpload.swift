//
//  WebDAVUpload.swift
//  DPProtocolWebDAV
//

import DPCore
import Foundation

/// A `PUT` whose body is produced as it is sent.
///
/// ## Swift note — Foundation's bound stream pair
/// `URLSession` will upload from a `Data` (needs the whole file in memory) or from a file on disk
/// (needs the file to exist). Neither fits `Session.write`, which is handed an `AsyncThrowingStream` of
/// chunks with no file behind it.
///
/// `Stream.getBoundStreams` is the bridge: it returns an `InputStream` and an `OutputStream` joined by a
/// shared buffer. Hand the input half to `URLRequest.httpBodyStream` and write the chunks into the
/// output half. The pair handles flow control between them, so a slow network slows the writer rather
/// than filling memory.
///
/// The trap is that `OutputStream` is a run-loop API. Its `hasSpaceAvailable` is a poll rather than a
/// wait, so the pump has to retry rather than block — a run loop that may not be running would never
/// deliver the callback this would otherwise wait for.
///
/// See `docs/swift-notes.md`, section 40.
enum WebDAVUpload {

    /// How much the two halves of the pair share. One network buffer's worth: bigger wastes memory,
    /// smaller means more round trips through the pump.
    private static let bufferSize = 256 * 1_024

    /// Sends a `PUT` whose body comes from a stream.
    ///
    /// - Parameters:
    ///   - request: The `PUT`, with headers already set.
    ///   - contents: The bytes to send.
    ///   - path: What is being written, for the error if it fails.
    ///   - configuration: The session configuration to run on.
    ///   - authorization: The credentials, so a redirect within the server does not lose them.
    ///   - trust: Who decides about a certificate the system refused.
    /// - Throws: ``SessionError`` if the upload fails or the server refuses it.
    static func send(
        _ request: URLRequest,
        contents: AsyncThrowingStream<Data, any Error>,
        path: RemotePath,
        configuration: URLSessionConfiguration,
        authorization: String?,
        trust: TrustDecider?
    ) async throws {
        var input: InputStream?
        var output: OutputStream?
        Stream.getBoundStreams(withBufferSize: bufferSize, inputStream: &input, outputStream: &output)

        guard let input, let output else {
            throw SessionError.transport("Could not open a stream to upload with.")
        }

        var request = request
        request.httpBodyStream = input

        let session = URLSession(
            configuration: configuration,
            delegate: WebDAVConnectionDelegate(authorization: authorization, trust: trust),
            delegateQueue: nil
        )
        defer { session.finishTasksAndInvalidate() }

        // The pump runs alongside the upload rather than before it: `URLSession` reads the input half as
        // it goes, so writing everything first would deadlock on a file larger than the shared buffer.
        let writer = Task { try await pump(contents, into: output) }

        do {
            let (_, response) = try await session.data(for: request)

            // The response settles it, so the writer is finished with either way. Waiting for it here
            // would hang whenever a server answers *before* reading the body — a 401, a 403, a 507, or
            // a proxy refusing the encoding — because the pump would be writing into a stream nobody
            // reads again.
            writer.cancel()

            guard let http = response as? HTTPURLResponse else {
                throw SessionError.protocolViolation("The server did not answer with HTTP.")
            }
            guard (200..<300).contains(http.statusCode) else {
                throw WebDAVTransport.mapStatus(http.statusCode, path: path, method: .put)
            }

            // One reason to override a success: the *source* failed. A local file that became
            // unreadable half way through produces a truncated body the server may well accept, and
            // reporting that as a completed upload would be a lie about what is on the server.
            try await surfaceSourceFailure(from: writer)

        } catch let error as URLError {
            writer.cancel()
            throw WebDAVTransport.mapURLError(error, host: request.url?.host() ?? "the server")
        } catch {
            writer.cancel()
            throw error
        }
    }

    /// Rethrows a failure that came from the bytes being uploaded, ignoring one that came from stopping.
    private static func surfaceSourceFailure(from writer: Task<Void, any Error>) async throws {
        guard case .failure(let error) = await writer.result else { return }
        guard !(error is CancellationError) else { return }
        throw error
    }

    /// Writes every chunk into the output half, waiting when there is no room.
    private static func pump(
        _ contents: AsyncThrowingStream<Data, any Error>,
        into output: OutputStream
    ) async throws {
        output.open()
        defer { output.close() }

        for try await chunk in contents {
            var remaining = chunk
            while !remaining.isEmpty {
                try Task.checkCancellation()

                guard output.hasSpaceAvailable else {
                    // Polling rather than awaiting a callback: `OutputStream` delivers "space available"
                    // to a run loop, and this task has none. A millisecond is short enough not to be
                    // felt at network speeds and long enough not to spin a core.
                    try await Task.sleep(for: .milliseconds(1))
                    continue
                }

                let written = remaining.withUnsafeBytes { raw -> Int in
                    guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return 0 }
                    return output.write(base, maxLength: raw.count)
                }

                // The reader has gone: the server has what it wants, or has decided it wants none of
                // it. Either way that is the *response's* story to tell, not an error of ours — and
                // treating it as one turned a successful upload into "the upload stream closed early".
                guard written > 0 else { return }
                remaining = remaining.dropFirst(written)
            }
        }
    }
}
