//
//  LocalFileIO.swift
//  DPTransfer
//

import DPCore
import Foundation

/// Moves bytes between `AsyncThrowingStream<Data>` and files on disk.
///
/// Everything here streams. Nothing loads a whole file into memory, which is what keeps a 40 GB download
/// from needing 40 GB of RAM.
enum LocalFileIO {

    /// Bytes per chunk when reading a local file for upload.
    static let chunkSize = 65_536

    // MARK: - Writing

    /// Writes a stream to disk, creating parent directories as needed.
    ///
    /// - Parameters:
    ///   - stream: The bytes to write.
    ///   - url: Where to write them.
    ///   - offset: Byte offset to resume at. Non-zero appends to the existing file.
    ///   - onProgress: Called with each chunk's size as it lands.
    /// - Returns: Bytes written by this call, excluding anything already there.
    /// - Throws: ``SessionError/transport(_:)`` if the file cannot be opened or written.
    static func write(
        _ stream: AsyncThrowingStream<Data, any Error>,
        to url: URL,
        resumingAt offset: Int64 = 0,
        onProgress: (Int) async -> Void = { _ in }
    ) async throws -> Int64 {
        try createParentDirectory(of: url)

        if offset == 0 || !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }

        guard let handle = FileHandle(forWritingAtPath: url.path) else {
            throw SessionError.transport("could not open \(url.lastPathComponent) for writing")
        }
        defer { try? handle.close() }

        do {
            if offset > 0 {
                try handle.seek(toOffset: UInt64(offset))
            } else {
                try handle.truncate(atOffset: 0)
            }

            var written: Int64 = 0
            for try await chunk in stream {
                try Task.checkCancellation()
                try handle.write(contentsOf: chunk)
                written += Int64(chunk.count)
                await onProgress(chunk.count)
            }
            return written
        } catch is CancellationError {
            throw SessionError.cancelled
        } catch let error as SessionError {
            throw error
        } catch {
            throw SessionError.transport(error.localizedDescription)
        }
    }

    // MARK: - Reading

    /// Streams a local file in chunks, for upload.
    ///
    /// - Parameters:
    ///   - url: The file to read.
    ///   - offset: Byte offset to start at.
    ///   - onProgress: Called with each chunk's size as it is produced.
    /// - Returns: A stream of the file's bytes.
    static func read(
        _ url: URL,
        from offset: Int64 = 0,
        onProgress: @escaping @Sendable (Int) async -> Void = { _ in }
    ) -> AsyncThrowingStream<Data, any Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                guard let handle = FileHandle(forReadingAtPath: url.path) else {
                    continuation.finish(
                        throwing: SessionError.transport("could not open \(url.lastPathComponent)"))
                    return
                }
                defer { try? handle.close() }

                do {
                    if offset > 0 { try handle.seek(toOffset: UInt64(offset)) }

                    while true {
                        try Task.checkCancellation()
                        // `read(upToCount:)` returns nil at end of file, and may legitimately return
                        // fewer bytes than asked for before then.
                        guard let chunk = try handle.read(upToCount: chunkSize), !chunk.isEmpty else {
                            break
                        }
                        continuation.yield(chunk)
                        await onProgress(chunk.count)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: - Paths

    /// The size of a local file, or `nil` if it is missing or unreadable.
    /// - Parameter url: The file to measure.
    static func size(of url: URL) -> Int64? {
        guard let values = try? url.resourceValues(forKeys: [.fileSizeKey]),
              let size = values.fileSize
        else { return nil }
        return Int64(size)
    }

    /// A name that is not taken yet, appending ` 2`, ` 3`, … before the extension.
    ///
    /// Matches how Finder names copies, so the result looks familiar rather than machine-generated.
    /// Shared by both sides of a transfer: `isTaken` checks the local disk for a download and the server
    /// for an upload, so the naming rule itself lives in exactly one place.
    ///
    /// - Parameters:
    ///   - stem: The name without its extension.
    ///   - ext: The extension without its dot, or `""`.
    ///   - isTaken: Whether a candidate name is already in use.
    /// - Returns: The first free name.
    static func uniqueName(
        stem: String,
        extension ext: String,
        isTaken: (String) async -> Bool
    ) async -> String {
        func name(_ suffix: Int) -> String {
            ext.isEmpty ? "\(stem) \(suffix)" : "\(stem) \(suffix).\(ext)"
        }

        for suffix in 2...1000 where await !isTaken(name(suffix)) {
            return name(suffix)
        }
        // A thousand collisions means something is wrong; a unique suffix beats looping forever.
        return ext.isEmpty ? "\(stem) \(UUID().uuidString)" : "\(stem) \(UUID().uuidString).\(ext)"
    }

    /// A local URL that does not exist yet.
    ///
    /// - Parameter url: The wanted location.
    /// - Returns: `url` itself when free, otherwise the first numbered variant that is.
    static func uniqueURL(for url: URL) async -> URL {
        guard FileManager.default.fileExists(atPath: url.path) else { return url }

        let directory = url.deletingLastPathComponent()
        let name = await uniqueName(
            stem: url.deletingPathExtension().lastPathComponent,
            extension: url.pathExtension
        ) { candidate in
            FileManager.default.fileExists(atPath: directory.appending(path: candidate).path)
        }
        return directory.appending(path: name)
    }

    /// Creates the directory containing `url` if it is missing.
    /// - Parameter url: The file whose parent is needed.
    static func createParentDirectory(of url: URL) throws {
        let parent = url.deletingLastPathComponent()
        guard !FileManager.default.fileExists(atPath: parent.path) else { return }
        do {
            try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        } catch {
            throw SessionError.transport("could not create \(parent.lastPathComponent): \(error.localizedDescription)")
        }
    }
}
