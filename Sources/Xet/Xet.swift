#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#endif

import Foundation
#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif
#if canImport(os)
    import os
#endif

/// Progress update for a single file download.
///
/// Progress callbacks may arrive concurrently from multiple threads.
/// To update UI, dispatch to the main actor within your handler.
public struct DownloadProgress: Sendable, Equatable {
    /// Total expected bytes (decompressed).
    public let totalBytes: Int64
    /// Bytes written so far (decompressed).
    public let bytesWritten: Int64
    /// Fraction completed (0.0 to 1.0), clamped.
    public var fractionCompleted: Double {
        guard totalBytes > 0 else { return 0 }
        return min(1.0, Double(bytesWritten) / Double(totalBytes))
    }
}

/// Namespace for Xet download helpers.
///
/// Use ``withDownloader(refreshURL:hubToken:configuration:_:)``
/// to create a downloader with a scoped lifetime,
///
/// ## Usage
///
/// Download a file to memory:
///
/// ```swift
/// let data = try await Xet.withDownloader(
///     refreshURL: tokenURL,
///     hubToken: "hf_..."
/// ) { downloader in
///     try await downloader.data(for: fileID)
/// }
/// ```
///
/// Download a file to disk:
///
/// ```swift
/// try await Xet.withDownloader(
///     refreshURL: tokenURL,
///     hubToken: "hf_..."
/// ) { downloader in
///     try await downloader.download(fileID, to: destinationURL)
/// }
/// ```
///
/// Both methods support partial downloads via the `byteRange` parameter.
/// The downloader handles chunk-level alignment automatically,
/// skipping bytes at the start and truncating at the end as needed.
public enum Xet {
    /// Creates a downloader for the duration of the closure.
    public static func withDownloader<T>(
        refreshURL: URL,
        hubToken: String? = nil,
        configuration: XetDownloader.Configuration = .default,
        _ body: (XetDownloader) async throws -> T
    ) async throws -> T {
        let downloader = XetDownloader(
            refreshURL: refreshURL,
            hubToken: hubToken,
            configuration: configuration
        )
        defer { downloader.invalidate() }
        return try await body(downloader)
    }
}

/// Downloader for Hugging Face CAS files using the Xet protocol.
///
/// Use ``Xet/withDownloader(refreshURL:hubToken:configuration:_:)``
/// to create a downloader with a scoped lifetime.
public final class XetDownloader: @unchecked Sendable {
    /// Hub token refresh endpoint for CAS credentials.
    private let refreshURL: URL

    /// Optional Hub token used to authenticate refresh requests.
    private let hubToken: String?

    /// Provides cached CAS access tokens with refresh coalescing.
    private let tokenProvider: TokenProvider

    /// Client for CAS reconstruction metadata requests.
    private let casClient: CASClient

    /// Delegate for xorb data tasks that tracks download progress.
    private let fetchDelegate: FetchDelegate

    /// URL session for xorb data fetches, using the fetch delegate.
    private let urlSession: URLSession

    /// Downloader configuration settings.
    private let configuration: Configuration

    #if canImport(os)
        private static let logger = Logger(
            subsystem: "com.huggingface.xet",
            category: "XetDownloader"
        )
    #endif

    /// Configuration for tuning downloader performance.
    public struct Configuration: Sendable {
        /// Maximum number of xorb fetches running at once. Defaults to 128.
        public var maxConcurrentFetches: Int = 128

        /// Maximum number of chunk decode operations running at once.
        /// Defaults to the active processor count.
        public var maxConcurrentDecodes: Int = max(
            1,
            ProcessInfo.processInfo.activeProcessorCount
        )

        /// Request timeout for HTTP requests, in seconds. Defaults to 120.
        public var requestTimeout: TimeInterval = 120

        /// Maximum number of attempts per xorb fetch, including the initial
        /// attempt. Set to 1 to disable retries. Defaults to 5.
        ///
        /// The Rust xet-core `retry_max_attempts` counts only retries (not the
        /// initial attempt), so Rust's default of 5 allows 6 total attempts.
        public var maxRetryAttempts: Int = 5

        /// Base delay between retry attempts, in seconds. Defaults to 3.
        /// Actual delay uses exponential backoff with jitter.
        public var retryBaseDelay: TimeInterval = 3

        /// Maximum total time to spend retrying a single fetch, in seconds.
        /// Defaults to 360 (6 minutes).
        public var retryMaxDuration: TimeInterval = 360

        /// Whether to allow insecure (non-HTTPS) connections.
        ///
        /// By default, the downloader requires HTTPS for all CAS and fetch URLs.
        /// Set this to `true` only for local development or testing with
        /// non-production servers.
        ///
        /// - Warning: Enabling insecure connections in production is a security risk.
        ///   Tokens and file contents may be transmitted in plaintext.
        public var allowsInsecureConnections: Bool = false

        public static let `default` = Configuration()
    }

    /// Creates a downloader configured for a specific repository.
    ///
    /// - Parameters:
    ///   - refreshURL: The Hugging Face Hub URL for obtaining CAS tokens.
    ///     Format: `https://huggingface.co/api/{type}s/{repo}/xet-read-token/{ref}`
    ///   - hubToken: Optional Hugging Face Hub authentication token.
    ///     Required for private repositories.
    ///   - configuration: Downloader configuration.
    public init(
        refreshURL: URL,
        hubToken: String? = nil,
        configuration: Configuration = .default
    ) {
        self.refreshURL = refreshURL
        self.hubToken = hubToken
        self.configuration = configuration
        self.tokenProvider = TokenProvider(
            urlSession: .shared
        )
        self.casClient = CASClient(urlSession: .shared)
        self.fetchDelegate = FetchDelegate()
        let sessionConfig = URLSessionConfiguration.default
        sessionConfig.timeoutIntervalForRequest = configuration.requestTimeout
        sessionConfig.httpMaximumConnectionsPerHost = 24
        self.urlSession = URLSession(
            configuration: sessionConfig,
            delegate: fetchDelegate,
            delegateQueue: nil
        )
    }

    /// Invalidates the URL session, breaking the retain cycle with the delegate.
    ///
    /// Called automatically by ``Xet/withDownloader(refreshURL:hubToken:configuration:_:)``.
    /// If you create a downloader directly, call this when you are done.
    public func invalidate() {
        urlSession.invalidateAndCancel()
    }

    deinit {
        urlSession.invalidateAndCancel()
    }

    /// Downloads a file and returns its contents as `Data`.
    ///
    /// - Parameters:
    ///   - fileID: The 64-character hex file identifier (Merkle hash).
    ///   - byteRange: Optional byte range for partial downloads.
    ///     The range is half-open: `start..<end`.
    ///     An empty range (where `lowerBound == upperBound`) returns
    ///     an empty `Data` immediately without making any network requests.
    ///
    /// - Returns: The file contents, or the requested byte range.
    ///
    /// - Throws: ``XetDownloaderError`` for protocol-level failures,
    ///   ``XorbError`` for malformed chunk data,
    ///   ``LZ4Error`` for decompression failures,
    ///   or `URLError` for network failures.
    ///
    /// - Important: This method loads the entire file (or range) into memory.
    ///   For large files, use ``download(_:byteRange:to:)``
    ///   to write directly to disk instead.
    public func data(
        for fileID: String,
        byteRange: Range<UInt64>? = nil,
        progressHandler: (@Sendable (DownloadProgress) -> Void)? = nil
    ) async throws -> Data {
        if let byteRange, byteRange.isEmpty {
            progressHandler?(DownloadProgress(totalBytes: 0, bytesWritten: 0))
            return Data()
        }
        let writer = DataOutputWriter()
        let target = WriteTarget.inMemory(writer)
        _ = try await download(
            fileID: fileID,
            byteRange: byteRange,
            target: target,
            progressHandler: progressHandler
        )
        return await writer.data
    }

    /// Downloads a file and writes it to disk.
    ///
    /// - Parameters:
    ///   - fileID: The 64-character hex file identifier (Merkle hash).
    ///   - byteRange: Optional byte range for partial downloads.
    ///     The range is half-open: `start..<end`.
    ///     An empty range (where `lowerBound == upperBound`) creates
    ///     an empty file at the destination and returns `0` without
    ///     making any network requests.
    ///   - destinationURL: The file URL where contents will be written.
    ///     If a file exists at this path, it will be replaced.
    ///   - fileManager: The file manager to use for file operations.
    ///     Defaults to `.default`.
    ///
    /// - Returns: The number of bytes written.
    ///
    /// - Throws: ``XetDownloaderError`` for protocol-level failures,
    ///   ``XorbError`` for malformed chunk data,
    ///   ``LZ4Error`` for decompression failures,
    ///   `URLError` for network failures,
    ///   or file system errors if writing to disk fails.
    @discardableResult
    public func download(
        _ fileID: String,
        byteRange: Range<UInt64>? = nil,
        to destinationURL: URL,
        fileManager: FileManager = .default,
        progressHandler: (@Sendable (DownloadProgress) -> Void)? = nil
    ) async throws -> Int64 {
        if fileManager.fileExists(atPath: destinationURL.path) {
            try fileManager.removeItem(at: destinationURL)
        }
        guard fileManager.createFile(atPath: destinationURL.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown)
        }

        if let byteRange, byteRange.isEmpty {
            progressHandler?(DownloadProgress(totalBytes: 0, bytesWritten: 0))
            return 0
        }
        let writer = try FileOutputWriter(destinationURL: destinationURL)
        let target = WriteTarget.file(writer)
        do {
            let written = try await download(
                fileID: fileID,
                byteRange: byteRange,
                target: target,
                progressHandler: progressHandler
            )
            try await target.closeIfNeeded()
            return written
        } catch {
            await target.closeIfNeeded(catching: { closeError in
                if let data = "Xet: failed to close file after download error: \(closeError)\n".data(using: .utf8) {
                    FileHandle.standardError.write(data)
                }
            })
            throw error
        }
    }

    // MARK: - Progress

    /// Computes the total expected decompressed bytes for progress reporting.
    static func totalExpectedBytes(
        terms: [CASClient.ReconstructionResponse.Term],
        offsetIntoFirstRange: UInt64,
        maxBytesToWrite: UInt64?
    ) -> Int64 {
        let totalUnpacked = terms.reduce(Int64(0)) { $0 + Int64($1.unpackedLength) }
        let adjustedUnpacked = max(0, totalUnpacked - Int64(offsetIntoFirstRange))
        return if let maxBytesToWrite {
            min(Int64(maxBytesToWrite), adjustedUnpacked)
        } else {
            adjustedUnpacked
        }
    }

    // MARK: - Download

    /// Core download implementation that writes to any ``WriteTarget``.
    ///
    /// Processes reconstruction terms in order, fetching xorb data and
    /// decompressing chunks. Implements caching for xorbs referenced by
    /// multiple terms to avoid redundant downloads.
    private func download(
        fileID: String,
        byteRange: Range<UInt64>?,
        target: WriteTarget,
        progressHandler: (@Sendable (DownloadProgress) -> Void)? = nil
    ) async throws -> Int64 {
        // Validate file ID
        guard fileID.count == 64,
            fileID.allSatisfy({ $0.isHexDigit })
        else {
            throw XetDownloaderError.invalidFileID(fileID)
        }

        let conn = try await tokenProvider.connectionInfo(
            for: refreshURL,
            hubToken: hubToken
        )
        // Validate CAS URL uses HTTPS unless insecure connections are allowed
        if !configuration.allowsInsecureConnections && conn.casURL.scheme != "https" {
            throw XetDownloaderError.insecureURL(conn.casURL)
        }

        let reconstruction = try await casClient.reconstruction(
            of: fileID,
            casURL: conn.casURL,
            accessToken: conn.accessToken,
            byteRange: byteRange
        )
        let maxBytesToWrite: UInt64? = byteRange.map { UInt64($0.count) }
        var remainingBytesToWrite = maxBytesToWrite

        var bytesToSkipInFirstTerm = reconstruction.offsetIntoFirstRange

        var xorbUsageCount: [String: Int] = [:]
        for term in reconstruction.terms {
            xorbUsageCount[term.hash, default: 0] += 1
        }

        var termContexts: [TermContext] = []
        termContexts.reserveCapacity(reconstruction.terms.count)
        var expectedUnpackedBytesByKey: [FetchRangeKey: Int] = [:]
        for term in reconstruction.terms {
            guard let fetchInfos = reconstruction.fetchInfo[term.hash] else {
                throw XetDownloaderError.invalidReconstruction
            }
            guard
                let fetchInfo = fetchInfos.first(where: {
                    $0.range.lowerBound <= term.range.lowerBound
                        && $0.range.upperBound >= term.range.upperBound
                })
            else {
                throw XetDownloaderError.invalidReconstruction
            }

            guard let fetchURL = URL(string: fetchInfo.url) else {
                throw XetDownloaderError.invalidFetchURL(fetchInfo.url)
            }
            // Validate fetch URL uses HTTPS unless insecure connections are allowed
            if !configuration.allowsInsecureConnections && fetchURL.scheme != "https" {
                throw XetDownloaderError.insecureURL(fetchURL)
            }

            var request = URLRequest(url: fetchURL)
            request.httpMethod = "GET"
            request.setValue(fetchInfo.urlRangeHeaderValue, forHTTPHeaderField: "Range")
            let key = FetchRangeKey(
                hash: term.hash,
                start: fetchInfo.range.lowerBound,
                end: fetchInfo.range.upperBound,
                urlRangeStart: fetchInfo.urlRange.lowerBound,
                urlRangeEnd: fetchInfo.urlRange.upperBound
            )
            expectedUnpackedBytesByKey[key, default: 0] += Int(term.unpackedLength)

            termContexts.append(
                TermContext(
                    term: term,
                    fetchInfo: fetchInfo,
                    key: key,
                    request: request
                )
            )
        }

        let totalExpectedBytes = Self.totalExpectedBytes(
            terms: reconstruction.terms,
            offsetIntoFirstRange: reconstruction.offsetIntoFirstRange,
            maxBytesToWrite: maxBytesToWrite
        )

        progressHandler?(DownloadProgress(totalBytes: totalExpectedBytes, bytesWritten: 0))

        var chunkCache: [FetchRangeKey: FetchedXorb] = [:]

        var totalWritten: Int64 = 0
        var writeOffset: Int64 = 0
        let maxConcurrentFetches = max(1, configuration.maxConcurrentFetches)
        let fetchSemaphore = AsyncSemaphore(maxConcurrentTasks: maxConcurrentFetches)
        var inflightFetches: [FetchRangeKey: Task<FetchedXorb, Error>] = [:]
        let writeRaw = target.writeContentsOf

        let progressAggregator = DownloadProgressAggregator(
            totalExpectedBytes: totalExpectedBytes,
            handler: progressHandler
        )

        func termRange(from fetched: FetchedXorb, for term: CASClient.ReconstructionResponse.Term) throws -> Range<Int>
        {
            let startIndex = term.range.lowerBound - fetched.chunkRange.lowerBound
            let endIndex = term.range.upperBound - fetched.chunkRange.lowerBound
            guard startIndex >= 0, endIndex >= startIndex, endIndex < fetched.chunkByteIndices.count else {
                throw XetDownloaderError.invalidReconstruction
            }
            let startByte = fetched.chunkByteIndices[startIndex]
            let endByte = fetched.chunkByteIndices[endIndex]
            if startByte >= endByte {
                return startByte ..< startByte
            }
            return startByte ..< endByte
        }

        func writeTermData(base: Data, range: Range<Int>) async throws {
            var lower = range.lowerBound
            var upper = range.upperBound
            if lower >= upper {
                return
            }

            if bytesToSkipInFirstTerm > 0 {
                let available = upper - lower
                let skip = min(UInt64(available), bytesToSkipInFirstTerm)
                lower += Int(skip)
                bytesToSkipInFirstTerm -= skip
                if lower >= upper {
                    return
                }
            }

            if let remaining = remainingBytesToWrite {
                if remaining == 0 {
                    return
                }
                let available = upper - lower
                if UInt64(available) > remaining {
                    upper = lower + Int(remaining)
                }
                remainingBytesToWrite = remaining - UInt64(upper - lower)
            }

            let offset = writeOffset
            writeOffset += Int64(upper - lower)

            if let writeRaw {
                try base.withUnsafeBytes { raw in
                    guard let baseAddress = raw.baseAddress else {
                        throw XetDownloaderError.invalidReconstruction
                    }
                    let start = baseAddress.advanced(by: lower)
                    let slice = UnsafeRawBufferPointer(start: start, count: upper - lower)
                    try writeRaw(slice, offset)
                }
            } else {
                let chunk = base.subdata(in: lower ..< upper)
                try await target.write(chunk)
            }

            totalWritten += Int64(upper - lower)
            progressAggregator.setWrittenBytes(totalWritten)
        }

        func ensureFetchTask(for context: TermContext) {
            let term = context.term
            let key = context.key
            let shouldCacheAllForXorb = (xorbUsageCount[term.hash] ?? 0) > 1
            let expectedUnpackedLength = expectedUnpackedBytesByKey[key]

            if inflightFetches[key] != nil {
                return
            }
            if shouldCacheAllForXorb, chunkCache[key] != nil {
                return
            }

            let decompressedContribution = Int64(expectedUnpackedLength ?? 0)

            inflightFetches[key] = Task {
                await fetchSemaphore.wait()
                do {
                    let fetched = try await fetchXorbChunks(
                        termHash: term.hash,
                        fetchInfo: context.fetchInfo,
                        request: context.request,
                        expectedUnpackedLength: expectedUnpackedLength,
                        downloadProgressHandler: { bytesReceived, bytesExpected in
                            let fraction = bytesExpected > 0
                                ? Double(bytesReceived) / Double(bytesExpected)
                                : 0
                            let estimated = Int64(Double(decompressedContribution) * fraction)
                            progressAggregator.setFetchEstimate(
                                key: key,
                                estimatedBytes: estimated
                            )
                        }
                    )
                    // Keep the fetch estimate alive until the download loop
                    // writes the term data and calls setWrittenBytes. Removing
                    // it here would create a gap where the estimate is gone but
                    // writtenBytes hasn't caught up, causing progress to stall
                    // then jump when multiple xorbs complete concurrently.
                    await fetchSemaphore.signal()
                    return fetched
                } catch {
                    progressAggregator.removeFetchEstimate(key: key)
                    await fetchSemaphore.signal()
                    throw error
                }
            }
        }

        for (termIndex, context) in termContexts.enumerated() {
            let term = context.term
            let key = context.key
            if let remainingBytesToWrite, remainingBytesToWrite == 0 {
                break
            }

            if let cached = chunkCache[key] {
                let range = try termRange(from: cached, for: term)
                try await writeTermData(base: cached.data, range: range)
                continue
            }

            let shouldCacheAllForXorb = (xorbUsageCount[term.hash] ?? 0) > 1
            let prefetchLimit = min(termContexts.count, termIndex + maxConcurrentFetches)
            for prefetchIndex in termIndex ..< prefetchLimit {
                ensureFetchTask(for: termContexts[prefetchIndex])
            }
            ensureFetchTask(for: context)
            guard let fetchTask = inflightFetches[key] else {
                continue
            }

            let fetchedChunks = try await fetchTask.value
            inflightFetches[key] = nil

            if shouldCacheAllForXorb {
                chunkCache[key] = fetchedChunks
            }
            let range = try termRange(from: fetchedChunks, for: term)
            try await writeTermData(base: fetchedChunks.data, range: range)
            progressAggregator.removeFetchEstimate(key: key)
        }

        // Guarantee a final completion callback.
        progressAggregator.setWrittenBytes(totalExpectedBytes)

        return totalWritten
    }

    private func fetchXorbChunks(
        termHash: String,
        fetchInfo: CASClient.ReconstructionResponse.FetchInfo,
        request: URLRequest,
        expectedUnpackedLength: Int?,
        downloadProgressHandler: (@Sendable (Int64, Int64) -> Void)? = nil
    ) async throws -> FetchedXorb {
        guard let url = request.url else {
            throw XetDownloaderError.fetchFailed(statusCode: nil, url: URL(fileURLWithPath: "/"))
        }
        let maxAttempts = max(1, configuration.maxRetryAttempts)
        var delay = configuration.retryBaseDelay
        // Enforce a maximum retry duration as an additional safeguard.
        // The Rust implementation defines this config but does not use it;
        // retries there are bounded only by max attempts.
        let deadline = ContinuousClock.now + .seconds(configuration.retryMaxDuration)
        var lastError: Error?

        for attempt in 0 ..< maxAttempts {
            if attempt > 0 {
                let remaining = deadline - .now
                if remaining <= .zero {
                    break
                }
                // Exponential backoff (delay doubles each attempt) with jitter
                // in [0, delay]. The jitter matches Rust's tokio_retry; the
                // doubling differs from Rust's base^n to keep delays practical.
                let jittered = Duration.seconds(delay * Double.random(in: 0.0 ... 1.0))
                try await Task.sleep(for: min(jittered, remaining))
                delay *= 2
            }

            do {
                let (responseData, response) = try await fetchDelegate.data(
                    for: request,
                    session: urlSession,
                    progressHandler: downloadProgressHandler
                )
                guard let httpResponse = response as? HTTPURLResponse else {
                    // A missing HTTP response typically indicates a fundamental
                    // URL loading issue, not a transient network error.
                    throw XetDownloaderError.fetchFailed(statusCode: nil, url: url)
                }
                let statusCode = httpResponse.statusCode
                guard (200 ..< 300).contains(statusCode) else {
                    throw XetDownloaderError.fetchFailed(statusCode: statusCode, url: url)
                }
                let decoded = try decodeXorbData(
                    responseData,
                    expectedUnpackedLength: expectedUnpackedLength
                )
                return FetchedXorb(
                    data: decoded.data,
                    chunkByteIndices: decoded.chunkByteIndices,
                    chunkRange: fetchInfo.range
                )
            } catch {
                guard Self.isRetryable(error) else {
                    throw error
                }
                lastError = error
                #if canImport(os)
                    Self.logger.warning(
                        "Retryable error on attempt \(attempt + 1)/\(maxAttempts) for \(url.lastPathComponent): \(error.localizedDescription)"
                    )
                #endif
            }
        }

        throw lastError ?? XetDownloaderError.fetchFailed(statusCode: nil, url: url)
    }

    /// Whether an error from a xorb fetch is worth retrying.
    static func isRetryable(_ error: Error) -> Bool {
        if case let XetDownloaderError.fetchFailed(statusCode, _) = error,
            let code = statusCode
        {
            return code == 408 || code == 429 || code >= 500
        }

        if let urlError = error as? URLError {
            switch urlError.code {
            case .timedOut, .networkConnectionLost, .notConnectedToInternet,
                .cannotConnectToHost, .dnsLookupFailed,
                .internationalRoamingOff, .dataNotAllowed:
                return true
            default:
                return false
            }
        }

        if let xorbError = error as? XorbError {
            switch xorbError {
            case .truncatedStream, .decompressionFailed, .lengthMismatch, .invalidLength:
                return true
            case .unsupportedVersion, .unsupportedCompressionScheme:
                return false
            }
        }

        return false
    }

    private func decodeXorbData(
        _ responseData: Data,
        expectedUnpackedLength: Int?
    ) throws -> (data: Data, chunkByteIndices: [Int]) {
        if let expectedUnpackedLength, expectedUnpackedLength > 0 {
            return try decodeXorbDataPreallocated(
                responseData,
                totalOutputSize: expectedUnpackedLength
            )
        }

        var cursor = ByteCursor()
        var data = Data()
        var chunkByteIndices: [Int] = [0]

        cursor.append(responseData)

        while true {
            if let uncompressed = try Xorb.decodeNextChunk(from: &cursor) {
                data.append(uncompressed)
                chunkByteIndices.append(data.count)
                continue
            }
            if cursor.count == 0 {
                break
            }
            throw XorbError.truncatedStream
        }

        return (data: data, chunkByteIndices: chunkByteIndices)
    }

    private func decodeXorbDataPreallocated(
        _ responseData: Data,
        totalOutputSize: Int
    ) throws -> (data: Data, chunkByteIndices: [Int]) {
        let outputBuffer = UnsafeMutableRawPointer.allocate(
            byteCount: totalOutputSize,
            alignment: 16
        )
        var outputBufferToFree: UnsafeMutableRawPointer? = outputBuffer
        defer {
            outputBufferToFree?.deallocate()
        }

        var cursor = ByteCursor()
        var chunkByteIndices: [Int] = [0]
        chunkByteIndices.reserveCapacity(1024)
        var writeOffset = 0

        cursor.append(responseData)

        while cursor.count >= 8 {
            guard let headerBytes = cursor.peek(count: 8) else { break }
            let header = try headerBytes.withUnsafeBytes { try Xorb.parseHeader($0) }
            let totalLength = 8 + header.compressedLength

            guard cursor.count >= totalLength else { break }

            _ = cursor.skip(count: 8)
            guard writeOffset + header.uncompressedLength <= totalOutputSize else {
                throw XorbError.lengthMismatch(
                    expected: totalOutputSize,
                    actual: writeOffset + header.uncompressedLength
                )
            }
            let outputSlice = UnsafeMutableRawBufferPointer(
                start: outputBuffer.advanced(by: writeOffset),
                count: header.uncompressedLength
            )

            try cursor.withUnsafeReadableBytes { readable in
                let compressed = UnsafeRawBufferPointer(
                    start: readable.baseAddress,
                    count: header.compressedLength
                )
                switch header.compressionScheme {
                case .none:
                    guard header.compressedLength == header.uncompressedLength else {
                        throw XorbError.lengthMismatch(
                            expected: header.uncompressedLength,
                            actual: header.compressedLength
                        )
                    }
                    if let src = compressed.baseAddress, let dst = outputSlice.baseAddress {
                        memcpy(dst, src, header.compressedLength)
                    }

                case .lz4:
                    _ = try LZ4.decompressBlock(
                        compressed,
                        uncompressedLength: header.uncompressedLength,
                        output: outputSlice
                    )

                case .byteGrouping4LZ4:
                    let scratch = UnsafeMutableRawBufferPointer.allocate(
                        byteCount: header.uncompressedLength,
                        alignment: 16
                    )
                    defer { scratch.deallocate() }
                    _ = try LZ4.decompressBlock(
                        compressed,
                        uncompressedLength: header.uncompressedLength,
                        output: scratch
                    )
                    BG4.regroup(UnsafeRawBufferPointer(scratch), into: outputSlice)
                }
            }

            cursor.consume(count: header.compressedLength)
            writeOffset += header.uncompressedLength
            chunkByteIndices.append(writeOffset)
        }

        if cursor.count > 0 {
            throw XorbError.truncatedStream
        }

        let data = Data(
            bytesNoCopy: outputBuffer,
            count: writeOffset,
            deallocator: .custom { ptr, _ in ptr.deallocate() }
        )
        outputBufferToFree = nil
        return (data: data, chunkByteIndices: chunkByteIndices)
    }

    private struct TermContext {
        let term: CASClient.ReconstructionResponse.Term
        let fetchInfo: CASClient.ReconstructionResponse.FetchInfo
        let key: FetchRangeKey
        let request: URLRequest
    }
}

/// Async semaphore for limiting concurrency.
private actor AsyncSemaphore {
    /// Available permits for waiters.
    private var availablePermits: Int
    /// FIFO queue of suspended waiters.
    private var waiters: [CheckedContinuation<Void, Never>] = []

    /// Creates a semaphore with the specified limit.
    init(maxConcurrentTasks: Int) {
        self.availablePermits = max(0, maxConcurrentTasks)
    }

    /// Waits for a permit to become available.
    func wait() async {
        if availablePermits > 0 {
            availablePermits -= 1
            return
        }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    /// Releases a permit to the next waiter.
    func signal() {
        if !waiters.isEmpty {
            let waiter = waiters.removeFirst()
            waiter.resume()
        } else {
            availablePermits += 1
        }
    }
}

// MARK: - Fetch Delegate

/// URLSession data delegate that accumulates received data per task
/// and reports download progress as bytes arrive.
private final class FetchDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let lock = NSLock()

    private struct TaskState {
        var data: Data
        var continuation: CheckedContinuation<(Data, URLResponse), Error>
        var progressHandler: (@Sendable (Int64, Int64) -> Void)?
        var response: URLResponse?
    }

    private var taskStates: [Int: TaskState] = [:]

    /// Performs a data request using the callback-based API so that the
    /// delegate receives `didReceive data:` callbacks for progress tracking.
    func data(
        for request: URLRequest,
        session: URLSession,
        progressHandler: (@Sendable (Int64, Int64) -> Void)? = nil
    ) async throws -> (Data, URLResponse) {
        let taskHolder = TaskHolder()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let task = session.dataTask(with: request)
                taskHolder.setTask(task)
                lock.withLock {
                    taskStates[task.taskIdentifier] = TaskState(
                        data: Data(),
                        continuation: continuation,
                        progressHandler: progressHandler,
                        response: nil
                    )
                }
                if Task.isCancelled {
                    task.cancel()
                }
                task.resume()
            }
        } onCancel: {
            taskHolder.cancel()
        }
    }

    /// Thread-safe holder for a URLSessionTask, used to propagate
    /// Swift task cancellation to the underlying network request.
    private final class TaskHolder: @unchecked Sendable {
        private let lock = NSLock()
        private var task: URLSessionDataTask?

        func setTask(_ task: URLSessionDataTask) {
            lock.lock()
            self.task = task
            lock.unlock()
        }

        func cancel() {
            lock.lock()
            let task = self.task
            lock.unlock()
            task?.cancel()
        }
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void
    ) {
        lock.withLock {
            taskStates[dataTask.taskIdentifier]?.response = response
        }
        completionHandler(.allow)
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive receivedData: Data
    ) {
        let bytesExpected = dataTask.countOfBytesExpectedToReceive
        let id = dataTask.taskIdentifier

        lock.lock()
        taskStates[id]?.data.append(receivedData)
        let handler = taskStates[id]?.progressHandler
        let bytesReceived = Int64(taskStates[id]?.data.count ?? 0)
        lock.unlock()

        handler?(bytesReceived, bytesExpected)
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        let state: TaskState? = lock.withLock {
            taskStates.removeValue(forKey: task.taskIdentifier)
        }
        guard let state else { return }
        if let error {
            state.continuation.resume(throwing: error)
        } else if let response = state.response {
            state.continuation.resume(returning: (state.data, response))
        } else {
            state.continuation.resume(throwing: URLError(.badServerResponse))
        }
    }
}

// MARK: - Download Progress Aggregator

/// Aggregates per-fetch network progress estimates with written bytes
/// to provide smooth overall download progress.
private final class DownloadProgressAggregator: @unchecked Sendable {
    private let lock = NSLock()
    private var writtenBytes: Int64 = 0
    private var highWaterMark: Int64 = 0
    private var fetchEstimates: [FetchRangeKey: Int64] = [:]
    private let totalExpectedBytes: Int64
    private let handler: (@Sendable (DownloadProgress) -> Void)?

    init(
        totalExpectedBytes: Int64,
        handler: (@Sendable (DownloadProgress) -> Void)?
    ) {
        self.totalExpectedBytes = totalExpectedBytes
        self.handler = handler
    }

    func setWrittenBytes(_ bytes: Int64) {
        guard let handler else { return }
        let progress: DownloadProgress = lock.withLock {
            writtenBytes = bytes
            return computeProgress()
        }
        handler(progress)
    }

    func setFetchEstimate(key: FetchRangeKey, estimatedBytes: Int64) {
        guard let handler else { return }
        let progress: DownloadProgress = lock.withLock {
            fetchEstimates[key] = estimatedBytes
            return computeProgress()
        }
        handler(progress)
    }

    func removeFetchEstimate(key: FetchRangeKey) {
        lock.lock()
        fetchEstimates.removeValue(forKey: key)
        lock.unlock()
    }

    private func computeProgress() -> DownloadProgress {
        let fetchContribution = fetchEstimates.values.reduce(Int64(0), +)
        let estimated = min(writtenBytes + fetchContribution, totalExpectedBytes)
        highWaterMark = max(highWaterMark, estimated)
        return DownloadProgress(
            totalBytes: totalExpectedBytes,
            bytesWritten: highWaterMark
        )
    }
}

// MARK: - Errors

/// Errors that can occur during Xet file downloads.
public enum XetDownloaderError: Error, Sendable {
    /// The token refresh request returned an invalid response.
    case invalidTokenResponse

    /// The token refresh request failed with an HTTP error.
    case tokenRequestFailed(statusCode: Int, body: Data)

    /// The CAS URL in the token response could not be parsed.
    case invalidCASURL(String)

    /// The CAS reconstruction request returned an invalid response.
    case invalidReconstructionResponse

    /// The CAS reconstruction request failed with an HTTP error.
    case reconstructionRequestFailed(statusCode: Int, body: Data)

    /// Failed to decode the reconstruction response JSON.
    case reconstructionDecodingFailed(Error)

    /// The reconstruction response is malformed or missing required fetch info.
    case invalidReconstruction

    /// The HTTP request to fetch xorb data failed.
    case fetchFailed(statusCode: Int?, url: URL)

    /// The fetch info URL could not be parsed.
    case invalidFetchURL(String)

    /// The file ID is not a valid 64-character hex string.
    case invalidFileID(String)

    /// A URL does not use HTTPS and insecure connections are not allowed.
    case insecureURL(URL)
}

extension XetDownloaderError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .invalidTokenResponse:
            return "Token endpoint returned an invalid response."
        case let .tokenRequestFailed(statusCode, _):
            return "Token request failed with HTTP status \(statusCode)."
        case let .invalidCASURL(url):
            return "Invalid or insecure CAS URL: \(url)"
        case .invalidReconstructionResponse:
            return "Reconstruction endpoint returned an invalid response."
        case let .reconstructionRequestFailed(statusCode, _):
            return "Reconstruction request failed with HTTP status \(statusCode)."
        case let .reconstructionDecodingFailed(error):
            return "Failed to decode reconstruction response: \(error.localizedDescription)"
        case .invalidReconstruction:
            return "Reconstruction response is malformed or missing required data."
        case let .fetchFailed(statusCode, url):
            if let code = statusCode {
                return "Failed to fetch xorb data from \(url.host ?? "unknown"): HTTP \(code)"
            }
            return "Failed to fetch xorb data from \(url.host ?? "unknown")."
        case let .invalidFetchURL(url):
            return "Invalid fetch URL: \(url)"
        case let .invalidFileID(id):
            return "Invalid file ID (expected 64 hex characters): \(id.prefix(20))..."
        case let .insecureURL(url):
            return "Insecure URL not allowed: \(url). Set allowsInsecureConnections to true for local development."
        }
    }
}

// MARK: - TokenProvider

extension XetDownloader {
    /// Manages CAS access tokens with caching and coalesced refresh.
    ///
    /// Tokens are cached by refresh URL and Hub token combination.
    /// Concurrent requests for the same token are coalesced into a single
    /// network request.
    actor TokenProvider {
        /// URL session used for token refresh requests.
        private let urlSession: URLSession

        /// Window before expiration to treat tokens as stale.
        private let safetyWindow: TimeInterval

        /// Key for cached connection info.
        private struct CacheKey: Hashable, Sendable {
            let refreshURL: URL
            let hubToken: String?
        }

        /// CAS connection details obtained from the Hub token endpoint.
        struct ConnectionInfo: Equatable, Sendable {
            /// The CAS API base URL.
            let casURL: URL

            /// The bearer token for CAS API authentication.
            let accessToken: String

            /// When the access token expires.
            let expiresAt: Date
        }

        /// Cached connection info by refresh URL and Hub token.
        private var cache: [CacheKey: ConnectionInfo] = [:]

        /// Inflight token refresh tasks by cache key.
        private var inflight: [CacheKey: Task<ConnectionInfo, Error>] = [:]

        /// Creates a token provider.
        ///
        /// - Parameters:
        ///   - urlSession: The URL session for token requests.
        ///   - safetyWindow: Seconds before expiration to consider a token stale.
        ///     Defaults to 60 seconds.
        init(
            urlSession: URLSession = .shared,
            safetyWindow: TimeInterval = 60
        ) {
            self.urlSession = urlSession
            self.safetyWindow = safetyWindow
        }

        /// Obtains CAS connection info, using cached tokens when valid.
        ///
        /// - Parameters:
        ///   - refreshURL: The Hugging Face Hub token endpoint.
        ///   - hubToken: Optional Hub authentication token.
        ///
        /// - Returns: Connection info with CAS URL and access token.
        func connectionInfo(for refreshURL: URL, hubToken: String?) async throws -> ConnectionInfo {
            let key = CacheKey(refreshURL: refreshURL, hubToken: hubToken)

            if let cached = cache[key],
                cached.expiresAt > Date().addingTimeInterval(safetyWindow)
            {
                return cached
            }

            if let existing = inflight[key] {
                return try await existing.value
            }

            let task = Task { [urlSession] () throws -> ConnectionInfo in
                var request = URLRequest(url: refreshURL)
                request.httpMethod = "GET"
                request.cachePolicy = .reloadIgnoringLocalCacheData
                if let hubToken {
                    request.setValue("Bearer \(hubToken)", forHTTPHeaderField: "Authorization")
                }

                let (data, response) = try await urlSession.data(for: request)
                guard let http = response as? HTTPURLResponse else {
                    throw XetDownloaderError.invalidTokenResponse
                }
                guard (200 ..< 300).contains(http.statusCode) else {
                    throw XetDownloaderError.tokenRequestFailed(
                        statusCode: http.statusCode,
                        body: data
                    )
                }

                let decoded: TokenResponse
                do {
                    decoded = try JSONDecoder().decode(TokenResponse.self, from: data)
                } catch {
                    throw XetDownloaderError.invalidTokenResponse
                }
                guard let casURL = URL(string: decoded.casUrl) else {
                    throw XetDownloaderError.invalidCASURL(decoded.casUrl)
                }

                let expiresAt = Date(timeIntervalSince1970: TimeInterval(decoded.exp))
                return ConnectionInfo(
                    casURL: casURL,
                    accessToken: decoded.accessToken,
                    expiresAt: expiresAt
                )
            }

            inflight[key] = task
            do {
                let value = try await task.value
                inflight[key] = nil
                cache[key] = value
                return value
            } catch {
                inflight[key] = nil
                throw error
            }
        }
    }

    /// JSON response from the Hub token endpoint.
    private struct TokenResponse: Equatable, Codable, Sendable {
        let accessToken: String
        let exp: Int
        let casUrl: String
    }
}

// MARK: - Private Helpers

/// Key for tracking which fetch ranges have been downloaded.
private struct FetchRangeKey: Hashable {
    let hash: String
    let start: Int
    let end: Int
    let urlRangeStart: UInt64
    let urlRangeEnd: UInt64
}

/// A fetched xorb chunk.
private struct FetchedXorb {
    let data: Data
    let chunkByteIndices: [Int]
    let chunkRange: Range<Int>
}

/// A destination for writing downloaded chunk data.
private struct WriteTarget: Sendable {
    /// Writes sequential chunk data in order.
    let write: @Sendable (Data) async throws -> Void

    /// Writes raw bytes to a specific output offset.
    let writeContentsOf: (@Sendable (UnsafeRawBufferPointer, Int64) throws -> Void)?

    /// Closes the destination when available.
    let close: (@Sendable () async throws -> Void)?

    static func inMemory(_ writer: DataOutputWriter) -> WriteTarget {
        WriteTarget(
            write: { chunk in
                try await writer.write(chunk)
            },
            writeContentsOf: nil,
            close: nil
        )
    }

    static func file(_ writer: FileOutputWriter) -> WriteTarget {
        WriteTarget(
            write: { chunk in
                try await writer.write(chunk)
            },
            writeContentsOf: { buffer, offset in
                try writer.write(contentsOf: buffer, at: offset)
            },
            close: {
                try await writer.close()
            }
        )
    }

    func closeIfNeeded() async throws {
        if let close {
            try await close()
        }
    }

    func closeIfNeeded(catching handler: (Error) -> Void) async {
        if let close {
            do {
                try await close()
            } catch {
                handler(error)
            }
        }
    }
}

/// An in-memory output writer that accumulates data.
actor DataOutputWriter {
    private(set) var data = Data()

    func write(_ data: Data) async throws {
        self.data.append(data)
    }
}

/// A random access output writer backed by POSIX pwrite.
final class FileOutputWriter: @unchecked Sendable {
    private let lock = NSLock()
    private var fd: Int32
    private var sequentialOffset: Int64 = 0

    init(destinationURL: URL) throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: destinationURL.path) {
            try fm.removeItem(at: destinationURL)
        }
        let flags = O_CREAT | O_RDWR | O_TRUNC
        let mode: mode_t = S_IRUSR | S_IWUSR | S_IRGRP | S_IROTH
        let fd = open(destinationURL.path, flags, mode)
        if fd < 0 {
            throw POSIXError(POSIXError.Code(rawValue: errno) ?? .EIO)
        }
        self.fd = fd
    }

    func write(contentsOf buffer: UnsafeRawBufferPointer, at offset: Int64) throws {
        if buffer.count == 0 {
            return
        }
        guard let baseAddress = buffer.baseAddress else {
            return
        }
        let currentFD = lock.withLock { fd }
        guard currentFD >= 0 else {
            throw POSIXError(.EBADF)
        }
        var bytesRemaining = buffer.count
        var localOffset = 0
        while bytesRemaining > 0 {
            let writeSize = bytesRemaining
            let written = pwrite(
                currentFD,
                baseAddress.advanced(by: localOffset),
                writeSize,
                off_t(offset + Int64(localOffset))
            )
            if written < 0 {
                throw POSIXError(POSIXError.Code(rawValue: errno) ?? .EIO)
            }
            bytesRemaining -= written
            localOffset += written
        }
    }

    func write(_ data: Data) async throws {
        let offset = lock.withLock {
            let offset = sequentialOffset
            sequentialOffset += Int64(data.count)
            return offset
        }
        try data.withUnsafeBytes { rawBuffer in
            try write(contentsOf: rawBuffer, at: offset)
        }
    }

    func close() async throws {
        let currentFD = lock.withLock {
            let currentFD = fd
            fd = -1
            return currentFD
        }
        guard currentFD >= 0 else {
            return
        }
        #if canImport(Darwin)
            let closeResult = Darwin.close(currentFD)
        #elseif canImport(Glibc)
            let closeResult = Glibc.close(currentFD)
        #else
            let closeResult = -1
        #endif
        if closeResult != 0 {
            throw POSIXError(POSIXError.Code(rawValue: errno) ?? .EIO)
        }
    }
}
