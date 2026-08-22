//
//  WebDAVDownload.swift
//  DPProtocolWebDAV
//

import DPCore
import Foundation

/// A `GET` whose body arrives as a stream of chunks.
///
/// ## Swift note — a callback API with backpressure
/// `URLSession.bytes(for:)` is the tidy way to stream a response and the wrong one here: it iterates a
/// byte at a time, which caps throughput far below what a local network gives. The delegate callback
/// hands over `Data` as it arrives, at full speed — and the cost is that nothing suspends the producer
/// when the consumer falls behind, because the callback is synchronous.
///
/// That is what ``ChunkBuffer`` is for. This type wires it to the one thing that can actually slow the
/// network down: `URLSessionTask.suspend()`.
///
/// See `docs/swift-notes.md`, section 39.
final class WebDAVDownload: WebDAVConnectionDelegate, URLSessionDataDelegate {

    private let buffer: ChunkBuffer
    private let path: RemotePath

    private let lock = NSLock()
    private var task: URLSessionDataTask?
    /// Set once the response headers have been seen and found acceptable.
    private var didAcceptResponse = false

    /// Whether the server honoured the `Range` header.
    ///
    /// A server is entitled to ignore it and send the whole file with a 200. Reported so the caller can
    /// tell the difference — appending a complete file to a partial one produces a corrupt result that
    /// is exactly the right length, which is the worst kind.
    private(set) var didResume = false

    private init(
        buffer: ChunkBuffer,
        path: RemotePath,
        authorization: String?,
        trust: TrustDecider?
    ) {
        self.buffer = buffer
        self.path = path
        super.init(authorization: authorization, trust: trust)
    }

    /// Starts a download and returns its body as chunks.
    ///
    /// - Parameters:
    ///   - request: The `GET`, with any `Range` header already set.
    ///   - path: What is being read, for the error if it fails.
    ///   - expectsRange: Whether a `Range` header was sent, so a plain 200 can be recognised as the
    ///     server declining to honour it.
    ///   - configuration: The session configuration to run on.
    ///   - authorization: The credentials, so a redirect within the server does not lose them.
    ///   - trust: Who decides about a certificate the system refused.
    /// - Returns: The chunks, in order.
    static func stream(
        _ request: URLRequest,
        path: RemotePath,
        expectsRange: Bool,
        configuration: URLSessionConfiguration,
        authorization: String?,
        trust: TrustDecider?
    ) -> AsyncThrowingStream<Data, any Error> {
        let buffer = ChunkBuffer()
        let downloader = WebDAVDownload(buffer: buffer, path: path,
                                        authorization: authorization, trust: trust)
        downloader.expectsRange = expectsRange

        // Its own session, because a delegate belongs to a session for that session's lifetime. It is
        // invalidated when the download ends, which is what releases the delegate.
        let session = URLSession(configuration: configuration, delegate: downloader, delegateQueue: nil)
        let task = session.dataTask(with: request)

        downloader.lock.lock()
        downloader.task = task
        downloader.lock.unlock()

        // Draining below the low mark is the signal to let the network run again.
        buffer.onResume = { [weak task] in task?.resume() }

        task.resume()

        // `unfolding`, not the `continuation` form, and the difference is the whole point of
        // ``ChunkBuffer``. A stream built with a continuation buffers **without bound** by default, so a
        // task looping `buffer.next()` into it would drain the buffer as fast as the network filled it,
        // the high-water mark would never be reached, the download would never be suspended, and an
        // entire file would end up in memory. Pulling one chunk per request from the consumer is what
        // lets the marks control the network as they were designed to.
        return AsyncThrowingStream {
            // Cancellation is handled here rather than through an `onCancel:` parameter, which the
            // throwing stream does not offer. Cancelling the URLSession task is what unsticks a consumer
            // waiting on an empty buffer: the delegate is told the task ended, finishes the buffer, and
            // the waiter resumes.
            try await withTaskCancellationHandler {
                do {
                    guard let chunk = try await buffer.next() else {
                        session.finishTasksAndInvalidate()
                        return nil
                    }
                    return chunk
                } catch {
                    session.finishTasksAndInvalidate()
                    throw error
                }
            } onCancel: {
                // Abandoning the stream — a cancelled transfer, a closed window — stops the download
                // rather than leaving it running to fill a buffer nobody is reading.
                task.cancel()
                session.invalidateAndCancel()
            }
        }
    }

    private var expectsRange = false

    // MARK: - URLSessionDataDelegate

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        guard let http = response as? HTTPURLResponse else {
            buffer.finish(throwing: SessionError.protocolViolation("The server did not answer with HTTP."))
            completionHandler(.cancel)
            return
        }
        guard (200..<300).contains(http.statusCode) else {
            buffer.finish(throwing: WebDAVTransport.mapStatus(http.statusCode, path: path, method: .get))
            completionHandler(.cancel)
            return
        }

        // 206 means the range was honoured. A 200 to a ranged request means it was not, and the body is
        // the whole file — which the caller must know, or it will append a complete file to a partial one.
        didResume = !expectsRange || http.statusCode == 206
        didAcceptResponse = true
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        // The synchronous callback that started all this. It cannot await, so the only lever is the
        // task itself.
        if buffer.append(data) == .pause {
            dataTask.suspend()
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        guard let error else {
            buffer.finish()
            return
        }

        let urlError = error as? URLError
        if urlError?.code == .cancelled {
            // Cancelling after the response was refused would replace the useful error with a vague one.
            if !didAcceptResponse { return }
            buffer.finish(throwing: SessionError.cancelled)
            return
        }
        buffer.finish(throwing: urlError.map {
            WebDAVTransport.mapURLError($0, host: task.originalRequest?.url?.host() ?? "the server")
        } ?? SessionError.transport(error.localizedDescription))
    }
}
