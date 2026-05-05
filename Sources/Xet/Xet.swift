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
/// This tracks reconstructed output bytes written to the destination, not
/// lower-level network transfer bytes for fetched Xet blocks.
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
        requestHeaders: [String: String] = [:],
        configuration: XetDownloader.Configuration = .default,
        _ body: (XetDownloader) async throws -> T
    ) async throws -> T {
        let downloader = XetDownloader(
            refreshURL: refreshURL,
            hubToken: hubToken,
            requestHeaders: requestHeaders,
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
public final class XetDownloader: Sendable {
    /// Hub token refresh endpoint for CAS credentials.
    private let refreshURL: URL

    /// Optional Hub token used to authenticate refresh requests.
    private let hubToken: String?

    /// Headers used for Hub token refresh requests.
    private let tokenRequestHeaders: [String: String]

    /// Hub request headers with authorization removed for CAS and xorb requests.
    private let xetRequestHeaders: [String: String]

    /// Provides cached CAS access tokens with refresh coalescing.
    private let tokenProvider: TokenProvider

    /// Client for CAS reconstruction metadata requests.
    private let casClient: CASClient

    /// Delegate for xorb data tasks that tracks download progress.
    private let fetchDelegate: FetchDelegate

    /// URL session for xorb data fetches, using the fetch delegate.
    private let urlSession: URLSession

    /// URL session for CAS reconstruction and token requests (no delegate).
    private let controlSession: URLSession

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

        /// Maximum number of retries per xorb fetch, after the initial attempt.
        /// Set to 0 to disable retries. Defaults to 5 (6 total attempts),
        /// matching xet-core's `retry_max_attempts`.
        public var maxRetries: Int = 5

        /// Base delay between retry attempts, in seconds. Defaults to 3.
        /// Actual delay uses exponential backoff with jitter.
        public var retryBaseDelay: TimeInterval = 3

        /// Maximum total time to spend retrying a single fetch, in seconds.
        /// Defaults to 360 (6 minutes).
        public var retryMaxDuration: TimeInterval = 360

        /// Whether to use V2 multi-range xorb fetches when CAS returns them.
        ///
        /// When `false`, V2 multi-range descriptors are split into separate
        /// single-range fetches against the same presigned URL. When `true`,
        /// each descriptor's ranges are combined into one HTTP request with a
        /// multi-range `Range` header (matching xet-core's behavior). Defaults
        /// to `false` until the Hub server side is verified to handle
        /// multi-range requests reliably.
        public var enableMultiRangeFetching: Bool = false

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
    ///   - requestHeaders: Additional Hub request headers to propagate to Xet token requests and, without authorization, CAS/xorb requests.
    ///   - configuration: Downloader configuration.
    public init(
        refreshURL: URL,
        hubToken: String? = nil,
        requestHeaders: [String: String] = [:],
        configuration: Configuration = .default
    ) {
        self.refreshURL = refreshURL
        self.hubToken = hubToken
        var refreshHeaders = requestHeaders
        if let hubToken {
            refreshHeaders = Self.xetRequestHeaders(from: requestHeaders)
            refreshHeaders["Authorization"] = "Bearer \(hubToken)"
        }
        self.tokenRequestHeaders = refreshHeaders
        self.xetRequestHeaders = Self.xetRequestHeaders(from: refreshHeaders)
        self.configuration = configuration
        self.fetchDelegate = FetchDelegate()
        let fetchConfig = URLSessionConfiguration.default
        fetchConfig.timeoutIntervalForRequest = configuration.requestTimeout
        fetchConfig.httpMaximumConnectionsPerHost = 24
        self.urlSession = URLSession(
            configuration: fetchConfig,
            delegate: fetchDelegate,
            delegateQueue: nil
        )
        let controlConfig = URLSessionConfiguration.default
        controlConfig.timeoutIntervalForRequest = configuration.requestTimeout
        self.controlSession = URLSession(configuration: controlConfig)
        self.casClient = CASClient(urlSession: controlSession)
        self.tokenProvider = TokenProvider(urlSession: controlSession)
    }

    private static func xetRequestHeaders(from headers: [String: String]) -> [String: String] {
        headers.filter { key, _ in
            key.caseInsensitiveCompare("authorization") != .orderedSame
        }
    }

    private static func applyHeaders(_ headers: [String: String], to request: inout URLRequest) {
        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }
    }

    /// Invalidates the URL session, breaking the retain cycle with the delegate.
    ///
    /// Called automatically by ``Xet/withDownloader(refreshURL:hubToken:configuration:_:)``.
    /// If you create a downloader directly, call this when you are done.
    public func invalidate() {
        urlSession.invalidateAndCancel()
        controlSession.invalidateAndCancel()
    }

    deinit {
        urlSession.invalidateAndCancel()
        controlSession.invalidateAndCancel()
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
    ///     An empty range (where `lowerBound == upperBound`) returns `0`
    ///     without making any network requests. Without append mode, it creates
    ///     an empty file at the destination.
    ///   - destinationURL: The file URL where contents will be written.
    ///     If a file exists at this path, it will be replaced.
    ///   - fileManager: The file manager to use for file operations.
    ///     Defaults to `.default`.
    ///   - appendingToExistingFile: If true, writes the downloaded bytes after
    ///     any existing destination bytes instead of replacing the file. The
    ///     destination size must match `byteRange.lowerBound`, or `0` when
    ///     `byteRange` is `nil`.
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
        appendingToExistingFile: Bool = false,
        progressHandler: (@Sendable (DownloadProgress) -> Void)? = nil
    ) async throws -> Int64 {
        let destinationExists = fileManager.fileExists(atPath: destinationURL.path)
        let appendOffset: Int64?
        if appendingToExistingFile {
            let requestedOffset = try Self.appendOffset(for: byteRange)
            let existingSize = try Self.fileSize(
                at: destinationURL,
                exists: destinationExists,
                fileManager: fileManager
            )
            guard existingSize == requestedOffset else {
                throw XetDownloaderError.appendSizeMismatch(
                    expected: requestedOffset,
                    actual: existingSize
                )
            }
            appendOffset = requestedOffset
        } else {
            appendOffset = nil
        }
        if !appendingToExistingFile, destinationExists {
            do {
                try fileManager.removeItem(at: destinationURL)
            } catch {
                throw XetDownloaderError.fileOperationFailed(
                    operation: "remove existing destination",
                    url: destinationURL,
                    underlying: error
                )
            }
        }
        if !appendingToExistingFile || !destinationExists {
            if !fileManager.createFile(atPath: destinationURL.path, contents: nil) {
                throw XetDownloaderError.destinationCreationFailed(destinationURL)
            }
        }

        if let byteRange, byteRange.isEmpty {
            progressHandler?(DownloadProgress(totalBytes: 0, bytesWritten: 0))
            return 0
        }
        let writer = try FileOutputWriter(
            destinationURL: destinationURL,
            appendOffset: appendOffset
        )
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
                #if canImport(os)
                    Self.logger.error(
                        "Failed to close destination file after download error: \(closeError.localizedDescription)"
                    )
                #endif
            })
            throw error
        }
    }

    private static func appendOffset(for byteRange: Range<UInt64>?) throws -> Int64 {
        let lowerBound = byteRange?.lowerBound ?? 0
        guard lowerBound <= UInt64(Int64.max) else {
            throw XetDownloaderError.byteRangeOutOfBounds(lowerBound)
        }
        return Int64(lowerBound)
    }

    private static func fileSize(
        at url: URL,
        exists: Bool,
        fileManager: FileManager
    ) throws -> Int64 {
        guard exists else { return 0 }
        let attrs: [FileAttributeKey: Any]
        do {
            attrs = try fileManager.attributesOfItem(atPath: url.path)
        } catch {
            throw XetDownloaderError.fileOperationFailed(
                operation: "read attributes",
                url: url,
                underlying: error
            )
        }
        if let size = attrs[.size] as? NSNumber {
            return size.int64Value
        }
        return attrs[.size] as? Int64 ?? 0
    }

    // MARK: - Progress

    /// Computes the total expected decompressed bytes for progress reporting.
    static func totalExpectedBytes(
        terms: [CASClient.ReconstructionResponse.Term],
        offsetIntoFirstRange: UInt64,
        maxBytesToWrite: UInt64?
    ) -> Int64 {
        let totalUnpacked = terms.reduce(Int64(0)) { $0 + Int64($1.unpackedLength) }
        let adjustedUnpacked = max(0, totalUnpacked - Int64(clamping: offsetIntoFirstRange))
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
            hubToken: hubToken,
            requestHeaders: tokenRequestHeaders,
            maxRetries: configuration.maxRetries,
            retryBaseDelay: configuration.retryBaseDelay,
            retryMaxDuration: configuration.retryMaxDuration
        )
        // Validate CAS URL uses HTTPS unless insecure connections are allowed
        if !configuration.allowsInsecureConnections && conn.casURL.scheme != "https" {
            throw XetDownloaderError.insecureURL(conn.casURL)
        }

        guard let reconstruction = try await casClient.reconstruction(
            of: fileID,
            casURL: conn.casURL,
            accessToken: conn.accessToken,
            requestHeaders: xetRequestHeaders,
            byteRange: byteRange,
            enableMultiRangeFetching: configuration.enableMultiRangeFetching,
            maxRetries: configuration.maxRetries,
            retryBaseDelay: configuration.retryBaseDelay,
            retryMaxDuration: configuration.retryMaxDuration
        ) else {
            progressHandler?(DownloadProgress(totalBytes: 0, bytesWritten: 0))
            return 0
        }
        let maxBytesToWrite: UInt64? = byteRange.map { UInt64($0.count) }
        var remainingBytesToWrite = maxBytesToWrite

        var bytesToSkipInFirstTerm = reconstruction.offsetIntoFirstRange

        var xorbUsageCount: [String: Int] = [:]
        for term in reconstruction.terms {
            xorbUsageCount[term.hash, default: 0] += 1
        }

        var termContextBuilder: [TermContext] = []
        termContextBuilder.reserveCapacity(reconstruction.terms.count)
        var sizeCandidatesByKey: [FetchRangeKey: XorbBlockSizeCandidate] = [:]

        @Sendable func fetchInfo(
            for term: CASClient.ReconstructionResponse.Term,
            in reconstruction: CASClient.ReconstructionResponse
        ) throws -> CASClient.ReconstructionResponse.FetchInfo {
            guard let fetchInfos = reconstruction.fetchInfo[term.hash] else {
                throw XetDownloaderError.invalidReconstruction
            }
            guard
                let fetchInfo = fetchInfos.first(where: {
                    $0.contains(termRange: term.range)
                })
            else {
                throw XetDownloaderError.invalidReconstruction
            }
            return fetchInfo
        }

        @Sendable func makeFetchRequest(for fetchInfo: CASClient.ReconstructionResponse.FetchInfo) throws -> URLRequest {
            guard let fetchURL = URL(string: fetchInfo.url) else {
                throw XetDownloaderError.invalidFetchURL(fetchInfo.url)
            }
            // Validate fetch URL uses HTTPS unless insecure connections are allowed
            if !configuration.allowsInsecureConnections && fetchURL.scheme != "https" {
                throw XetDownloaderError.insecureURL(fetchURL)
            }

            var request = URLRequest(url: fetchURL)
            request.httpMethod = "GET"
            Self.applyHeaders(xetRequestHeaders, to: &request)
            request.setValue(fetchInfo.urlRangeHeaderValue, forHTTPHeaderField: "Range")
            return request
        }

        @Sendable func makeFetchRangeKey(
            hash: String,
            fetchInfo: CASClient.ReconstructionResponse.FetchInfo
        ) -> FetchRangeKey {
            FetchRangeKey(hash: hash, fetchInfo: fetchInfo)
        }

        for term in reconstruction.terms {
            let fetchInfo = try fetchInfo(for: term, in: reconstruction)
            let key = makeFetchRangeKey(hash: term.hash, fetchInfo: fetchInfo)
            var sizeCandidate = sizeCandidatesByKey[key] ?? XorbBlockSizeCandidate(
                chunkRanges: fetchInfo.ranges.map(\.chunkRange),
                references: []
            )
            sizeCandidate.references.append(
                XorbBlockReference(
                    chunkRange: term.range,
                    uncompressedSize: Int(term.unpackedLength)
                )
            )
            sizeCandidatesByKey[key] = sizeCandidate

            termContextBuilder.append(
                TermContext(
                    term: term,
                    fetchInfo: fetchInfo,
                    key: key
                )
            )
        }
        let termContexts = termContextBuilder
        let expectedUnpackedBytesByKey = sizeCandidatesByKey.compactMapValues {
            Self.uncompressedSizeIfKnown(
                chunkRanges: $0.chunkRanges,
                references: $0.references
            )
        }
        var initialFetchInfosByKey: [FetchRangeKey: CASClient.ReconstructionResponse.FetchInfo] = [:]
        for context in termContexts {
            initialFetchInfosByKey[context.key] = context.fetchInfo
        }
        let retrievalURLState = RetrievalURLState(fetchInfosByKey: initialFetchInfosByKey)

        let totalExpectedBytes = Self.totalExpectedBytes(
            terms: reconstruction.terms,
            offsetIntoFirstRange: reconstruction.offsetIntoFirstRange,
            maxBytesToWrite: maxBytesToWrite
        )

        progressHandler?(DownloadProgress(totalBytes: totalExpectedBytes, bytesWritten: 0))

        // TODO: If `huggingface_hub`/`hf_xet` wires xet-core's persistent
        // chunk cache into production downloads, add it here by wrapping
        // xet-core instead of maintaining a parallel Swift port.
        var localChunkCache: [FetchRangeKey: FetchedXorb] = [:]

        var totalWritten: Int64 = 0
        var writeOffset: Int64 = 0
        let maxConcurrentFetches = max(1, configuration.maxConcurrentFetches)
        let fetchSemaphore = AsyncSemaphore(maxConcurrentTasks: maxConcurrentFetches)
        var inflightFetches: [FetchRangeKey: Task<FetchedXorb, Error>] = [:]
        defer {
            for task in inflightFetches.values {
                task.cancel()
            }
        }
        let writeRaw = target.writeContentsOf

        func reportWrittenBytes(_ bytes: Int64) {
            progressHandler?(
                DownloadProgress(
                    totalBytes: totalExpectedBytes,
                    bytesWritten: min(bytes, totalExpectedBytes)
                )
            )
        }

        func termRange(from fetched: FetchedXorb, for term: CASClient.ReconstructionResponse.Term) throws -> Range<Int>
        {
            let startIndex = fetched.flattenedBoundaryIndex(forChunkBoundary: term.range.lowerBound)
            let endIndex = fetched.flattenedBoundaryIndex(forChunkBoundary: term.range.upperBound)
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
            reportWrittenBytes(totalWritten)
        }

        @Sendable func refreshedFetchInfosByKey() async throws -> [FetchRangeKey: CASClient.ReconstructionResponse.FetchInfo] {
            guard let refreshed = try await casClient.reconstruction(
                of: fileID,
                casURL: conn.casURL,
                accessToken: conn.accessToken,
                requestHeaders: xetRequestHeaders,
                byteRange: byteRange,
                enableMultiRangeFetching: configuration.enableMultiRangeFetching,
                maxRetries: configuration.maxRetries,
                retryBaseDelay: configuration.retryBaseDelay,
                retryMaxDuration: configuration.retryMaxDuration
            ) else {
                throw XetDownloaderError.invalidReconstruction
            }
            return try buildFetchInfosByKey(from: refreshed)
        }

        @Sendable func buildFetchInfosByKey(
            from reconstruction: CASClient.ReconstructionResponse
        ) throws -> [FetchRangeKey: CASClient.ReconstructionResponse.FetchInfo] {
            var refreshedFetchInfosByKey: [FetchRangeKey: CASClient.ReconstructionResponse.FetchInfo] = [:]
            for context in termContexts {
                let fetchInfo = try fetchInfo(for: context.term, in: reconstruction)
                let refreshedKey = makeFetchRangeKey(hash: context.term.hash, fetchInfo: fetchInfo)
                guard refreshedKey == context.key else {
                    throw XetDownloaderError.invalidReconstruction
                }
                refreshedFetchInfosByKey[context.key] = fetchInfo
            }
            return refreshedFetchInfosByKey
        }

        func ensureFetchTask(for context: TermContext) {
            let term = context.term
            let key = context.key
            let shouldCacheAllForXorb = (xorbUsageCount[term.hash] ?? 0) > 1
            let expectedUnpackedLength = expectedUnpackedBytesByKey[key]

            if inflightFetches[key] != nil {
                return
            }
            if shouldCacheAllForXorb, localChunkCache[key] != nil {
                return
            }

            inflightFetches[key] = Task {
                try await fetchSemaphore.wait()
                do {
                    let snapshot = try await retrievalURLState.snapshot(for: key)
                    let request = try makeFetchRequest(for: snapshot.fetchInfo)
                    let fetched = try await self.fetchXorbChunks(
                        termHash: term.hash,
                        fetchInfo: snapshot.fetchInfo,
                        request: request,
                        requestGeneration: snapshot.generation,
                        expectedUnpackedLength: expectedUnpackedLength,
                        refreshRequest: { observedGeneration in
                            let refreshedSnapshot = try await retrievalURLState.refreshedSnapshot(
                                for: key,
                                observedGeneration: observedGeneration,
                                refresh: refreshedFetchInfosByKey
                            )
                            return RefreshedFetchRequest(
                                generation: refreshedSnapshot.generation,
                                request: try makeFetchRequest(for: refreshedSnapshot.fetchInfo)
                            )
                        },
                        downloadProgressHandler: nil
                    )
                    await fetchSemaphore.signal()
                    return fetched
                } catch {
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

            if let cached = localChunkCache[key] {
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
                localChunkCache[key] = fetchedChunks
            }
            let range = try termRange(from: fetchedChunks, for: term)
            try await writeTermData(base: fetchedChunks.data, range: range)
        }

        // Guarantee a final completion callback.
        reportWrittenBytes(totalExpectedBytes)

        return totalWritten
    }

    private func fetchXorbChunks(
        termHash: String,
        fetchInfo: CASClient.ReconstructionResponse.FetchInfo,
        request: URLRequest,
        requestGeneration: Int,
        expectedUnpackedLength: Int?,
        refreshRequest: (@Sendable (Int) async throws -> RefreshedFetchRequest)? = nil,
        downloadProgressHandler: (@Sendable (Int64, Int64) -> Void)? = nil
    ) async throws -> FetchedXorb {
        var currentRequest = request
        var currentRequestGeneration = requestGeneration
        guard request.url != nil else {
            throw XetDownloaderError.fetchFailed(statusCode: nil, url: URL(fileURLWithPath: "/"))
        }
        let maxAttempts = max(1, configuration.maxRetries + 1)
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
                // in [0, delay]. Matches Rust's pre-jitter schedule of
                // 2^n * base, with a [0, 1) jitter factor.
                let jittered = Duration.seconds(delay * Double.random(in: 0.0 ... 1.0))
                try await Task.sleep(for: min(jittered, remaining))
                delay *= 2
            }

            do {
                guard let url = currentRequest.url else {
                    throw XetDownloaderError.fetchFailed(statusCode: nil, url: URL(fileURLWithPath: "/"))
                }
                let (responseData, response) = try await fetchDelegate.data(
                    for: currentRequest,
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
                    // Rust's `with_retry_on_403` reclassifies 403 as transient
                    // and refreshes the URL inside the request closure, so a
                    // 403 always triggers a refresh, even on the last attempt.
                    if statusCode == 403, let refreshRequest {
                        lastError = XetDownloaderError.fetchFailed(statusCode: statusCode, url: url)
                        let refreshed = try await refreshRequest(currentRequestGeneration)
                        currentRequest = refreshed.request
                        currentRequestGeneration = refreshed.generation
                        continue
                    }
                    throw XetDownloaderError.fetchFailed(statusCode: statusCode, url: url)
                }
                let decoded = try decodeXorbResponse(
                    responseData,
                    response: httpResponse,
                    fetchInfo: fetchInfo,
                    expectedUnpackedLength: expectedUnpackedLength
                )
                return FetchedXorb(
                    data: decoded.data,
                    chunkByteIndices: decoded.chunkByteIndices,
                    chunkRanges: fetchInfo.ranges.map(\.chunkRange)
                )
            } catch {
                guard Self.isRetryable(error) else {
                    throw error
                }
                lastError = error
                #if canImport(os)
                    Self.logger.warning(
                        "Retryable error on attempt \(attempt + 1)/\(maxAttempts) for \(currentRequest.url?.lastPathComponent ?? termHash): \(error.localizedDescription)"
                    )
                #endif
            }
        }

        throw lastError ?? XetDownloaderError.fetchFailed(
            statusCode: nil,
            url: currentRequest.url ?? URL(fileURLWithPath: "/")
        )
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
                .internationalRoamingOff, .dataNotAllowed,
                .cannotParseResponse:
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

    private func decodeXorbResponse(
        _ responseData: Data,
        response: HTTPURLResponse,
        fetchInfo: CASClient.ReconstructionResponse.FetchInfo,
        expectedUnpackedLength: Int?
    ) throws -> (data: Data, chunkByteIndices: [Int]) {
        let contentType = response.value(forHTTPHeaderField: "Content-Type") ?? ""
        guard contentType.localizedCaseInsensitiveContains("multipart/byteranges") else {
            return try decodeXorbData(responseData, expectedUnpackedLength: expectedUnpackedLength)
        }

        let parts = try MultipartByteRanges.parse(contentType: contentType, body: responseData)
        // Validate that the server returned exactly the ranges we requested,
        // sorted in the order we expect to consume them. A buggy or malicious
        // server returning unrelated ranges would otherwise silently produce
        // wrong file contents.
        let expectedRanges = fetchInfo.urlRanges.sorted { $0.lowerBound < $1.lowerBound }
        let returnedRanges = parts.map(\.range)
        guard returnedRanges == expectedRanges else {
            throw XetDownloaderError.invalidReconstruction
        }

        var data = Data()
        var chunkByteIndices: [Int] = [0]
        chunkByteIndices.reserveCapacity(parts.count + 1)

        for part in parts {
            let decoded = try decodeXorbData(part.data, expectedUnpackedLength: nil)
            appendDecodedSegment(
                data: decoded.data,
                chunkByteIndices: decoded.chunkByteIndices,
                toData: &data,
                toChunkByteIndices: &chunkByteIndices
            )
        }

        if let expectedUnpackedLength, data.count != expectedUnpackedLength {
            throw XorbError.lengthMismatch(expected: expectedUnpackedLength, actual: data.count)
        }

        return (data: data, chunkByteIndices: chunkByteIndices)
    }

    private func appendDecodedSegment(
        data segmentData: Data,
        chunkByteIndices segmentChunkByteIndices: [Int],
        toData data: inout Data,
        toChunkByteIndices chunkByteIndices: inout [Int]
    ) {
        let baseOffset = data.count
        data.append(segmentData)
        for index in segmentChunkByteIndices.dropFirst() {
            chunkByteIndices.append(baseOffset + index)
        }
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

    private struct TermContext: Sendable {
        let term: CASClient.ReconstructionResponse.Term
        let fetchInfo: CASClient.ReconstructionResponse.FetchInfo
        let key: FetchRangeKey
    }

    struct XorbBlockSizeCandidate: Sendable {
        let chunkRanges: [Range<Int>]
        var references: [XorbBlockReference]
    }

    struct XorbBlockReference: Sendable {
        let chunkRange: Range<Int>
        let uncompressedSize: Int
    }

    private struct RefreshedFetchRequest: Sendable {
        let generation: Int
        let request: URLRequest
    }

    static func uncompressedSizeIfKnown(
        chunkRanges: [Range<Int>],
        references: [XorbBlockReference]
    ) -> Int? {
        let sortedChunkRanges = chunkRanges.sorted { $0.lowerBound < $1.lowerBound }
        if sortedChunkRanges.isEmpty {
            return 0
        }
        guard sortedChunkRanges.allSatisfy({ !$0.isEmpty }) else {
            return nil
        }

        let sortedReferences = references.sorted { $0.chunkRange.lowerBound < $1.chunkRange.lowerBound }
        guard sortedReferences.allSatisfy({ reference in
            sortedChunkRanges.contains { range in
                range.lowerBound <= reference.chunkRange.lowerBound
                    && reference.chunkRange.upperBound <= range.upperBound
            }
        }) else {
            return nil
        }

        var gapBridges: [Int: Int] = [:]
        if sortedChunkRanges.count > 1 {
            for index in sortedChunkRanges.indices.dropLast() {
                let previous = sortedChunkRanges[index]
                let next = sortedChunkRanges[sortedChunkRanges.index(after: index)]
                if previous.upperBound < next.lowerBound {
                    gapBridges[previous.upperBound] = next.lowerBound
                }
            }
        }

        var reachable: [Int: Int] = [sortedChunkRanges[0].lowerBound: 0]
        for reference in sortedReferences {
            guard let accumulatedSize = reachable[reference.chunkRange.lowerBound] else {
                continue
            }
            let newEnd = reference.chunkRange.upperBound
            let newSize = accumulatedSize + reference.uncompressedSize
            if reachable[newEnd] == nil {
                reachable[newEnd] = newSize
            }
            if let bridgeTarget = gapBridges[newEnd], reachable[bridgeTarget] == nil {
                reachable[bridgeTarget] = newSize
            }
        }

        return reachable[sortedChunkRanges[sortedChunkRanges.count - 1].upperBound]
    }
}

private actor RetrievalURLState {
    struct Snapshot: Sendable {
        let generation: Int
        let fetchInfo: CASClient.ReconstructionResponse.FetchInfo
    }

    private var generation = 0
    private var fetchInfosByKey: [FetchRangeKey: CASClient.ReconstructionResponse.FetchInfo]
    private var refreshTask: Task<[FetchRangeKey: CASClient.ReconstructionResponse.FetchInfo], Error>?

    init(fetchInfosByKey: [FetchRangeKey: CASClient.ReconstructionResponse.FetchInfo]) {
        self.fetchInfosByKey = fetchInfosByKey
    }

    func snapshot(for key: FetchRangeKey) throws -> Snapshot {
        guard let fetchInfo = fetchInfosByKey[key] else {
            throw XetDownloaderError.invalidReconstruction
        }
        return Snapshot(generation: generation, fetchInfo: fetchInfo)
    }

    func refreshedSnapshot(
        for key: FetchRangeKey,
        observedGeneration: Int,
        refresh: @escaping @Sendable () async throws -> [FetchRangeKey: CASClient.ReconstructionResponse.FetchInfo]
    ) async throws -> Snapshot {
        if generation != observedGeneration {
            return try snapshot(for: key)
        }

        // Only the task creator owns `refreshTask` lifetime; joiners must not
        // clear it, since the slot may already hold a successor refresh task.
        let task: Task<[FetchRangeKey: CASClient.ReconstructionResponse.FetchInfo], Error>
        let isCreator: Bool
        if let refreshTask {
            task = refreshTask
            isCreator = false
        } else {
            task = Task {
                try await refresh()
            }
            refreshTask = task
            isCreator = true
        }

        do {
            let refreshedFetchInfosByKey = try await task.value
            if isCreator {
                defer { refreshTask = nil }
                if generation == observedGeneration {
                    guard Set(refreshedFetchInfosByKey.keys) == Set(fetchInfosByKey.keys) else {
                        throw XetDownloaderError.invalidReconstruction
                    }
                    for (key, fetchInfo) in refreshedFetchInfosByKey {
                        guard key.matches(fetchInfo: fetchInfo) else {
                            throw XetDownloaderError.invalidReconstruction
                        }
                    }
                    fetchInfosByKey = refreshedFetchInfosByKey
                    generation += 1
                }
            }
            return try snapshot(for: key)
        } catch {
            if isCreator {
                refreshTask = nil
            }
            throw error
        }
    }
}

/// Async semaphore for limiting concurrency.
private actor AsyncSemaphore {
    /// Available permits for waiters.
    private var availablePermits: Int

    private struct Waiter {
        let id: UUID
        let continuation: CheckedContinuation<Void, Error>
    }

    /// FIFO queue of suspended waiters.
    private var waiters: [Waiter] = []

    /// Creates a semaphore with the specified limit.
    init(maxConcurrentTasks: Int) {
        self.availablePermits = max(0, maxConcurrentTasks)
    }

    /// Waits for a permit to become available.
    ///
    /// Throws ``CancellationError`` if the calling task is cancelled before
    /// or while it is suspended waiting for a permit. A permit is acquired
    /// only when this returns normally; cancellation never silently
    /// transfers a permit, so callers should only ``signal()`` when ``wait()``
    /// returned successfully.
    func wait() async throws {
        try Task.checkCancellation()
        if availablePermits > 0 {
            availablePermits -= 1
            return
        }
        let waiterID = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                waiters.append(Waiter(id: waiterID, continuation: continuation))
            }
        } onCancel: {
            Task { await self.cancelWaiter(id: waiterID) }
        }
    }

    private func cancelWaiter(id: UUID) {
        if let index = waiters.firstIndex(where: { $0.id == id }) {
            let waiter = waiters.remove(at: index)
            waiter.continuation.resume(throwing: CancellationError())
        }
    }

    /// Releases a permit to the next waiter.
    func signal() {
        if !waiters.isEmpty {
            let waiter = waiters.removeFirst()
            waiter.continuation.resume()
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

// MARK: - Errors

/// Errors that can occur during Xet file downloads.
public enum XetDownloaderError: Error, Sendable {
    /// The token refresh request returned an invalid response.
    case invalidTokenResponse(underlying: Error?)

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

    /// The destination file's existing size does not match the expected
    /// append offset.
    case appendSizeMismatch(expected: Int64, actual: Int64)

    /// The requested byte range cannot be represented as a positive `Int64`
    /// file offset.
    case byteRangeOutOfBounds(UInt64)

    /// The destination file could not be created.
    case destinationCreationFailed(URL)

    /// A file system operation on the destination failed.
    case fileOperationFailed(operation: String, url: URL, underlying: Error)
}

extension XetDownloaderError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case let .invalidTokenResponse(underlying):
            if let underlying {
                return "Token endpoint returned an invalid response: \(underlying.localizedDescription)"
            }
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
            // Strip query and fragment so presigned credentials in fetch URLs
            // do not leak through error messages or logs.
            var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
            components?.query = nil
            components?.fragment = nil
            let safeURL = components?.url?.absoluteString ?? "\(url.scheme ?? "")://\(url.host ?? "unknown")"
            return "Insecure URL not allowed: \(safeURL). Set allowsInsecureConnections to true for local development."
        case let .appendSizeMismatch(expected, actual):
            return "Cannot append to file: expected size \(expected) bytes, found \(actual)."
        case let .byteRangeOutOfBounds(value):
            return "Byte range start \(value) exceeds the maximum supported file offset."
        case let .destinationCreationFailed(url):
            return "Could not create destination file at \(url.path)."
        case let .fileOperationFailed(operation, url, underlying):
            return "File operation '\(operation)' failed on \(url.path): \(underlying.localizedDescription)"
        }
    }
}

// MARK: - TokenProvider

extension XetDownloader {
    /// Manages CAS access tokens with caching and coalesced refresh.
    ///
        /// Tokens are cached by refresh URL and authorization context.
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
            let authorizationHeader: String?
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
        func connectionInfo(
            for refreshURL: URL,
            hubToken: String?,
            requestHeaders: [String: String] = [:],
            maxRetries: Int = XetDownloader.Configuration.default.maxRetries,
            retryBaseDelay: TimeInterval = XetDownloader.Configuration.default.retryBaseDelay,
            retryMaxDuration: TimeInterval = XetDownloader.Configuration.default.retryMaxDuration
        ) async throws -> ConnectionInfo {
            let authorizationHeader = Self.authorizationHeader(from: requestHeaders)
            let key = CacheKey(
                refreshURL: refreshURL,
                hubToken: hubToken,
                authorizationHeader: authorizationHeader
            )

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
                for (key, value) in requestHeaders {
                    request.setValue(value, forHTTPHeaderField: key)
                }
                if let hubToken {
                    request.setValue("Bearer \(hubToken)", forHTTPHeaderField: "Authorization")
                }

                return try await Self.connectionInfoWithRetry(
                    for: request,
                    urlSession: urlSession,
                    maxRetries: maxRetries,
                    retryBaseDelay: retryBaseDelay,
                    retryMaxDuration: retryMaxDuration
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

        private static func authorizationHeader(from headers: [String: String]) -> String? {
            for (key, value) in headers where key.caseInsensitiveCompare("authorization") == .orderedSame {
                return value
            }
            return nil
        }

        private static func connectionInfoWithRetry(
            for request: URLRequest,
            urlSession: URLSession,
            maxRetries: Int,
            retryBaseDelay: TimeInterval,
            retryMaxDuration: TimeInterval
        ) async throws -> ConnectionInfo {
            let maxAttempts = max(1, maxRetries + 1)
            var delay = retryBaseDelay
            let deadline = ContinuousClock.now + .seconds(retryMaxDuration)
            var lastError: Error?

            for attempt in 0 ..< maxAttempts {
                if attempt > 0 {
                    let remaining = deadline - .now
                    if remaining <= .zero {
                        break
                    }
                    let jittered = Duration.seconds(delay * Double.random(in: 0.0 ... 1.0))
                    try await Task.sleep(for: min(jittered, remaining))
                    delay *= 2
                }

                do {
                    let (data, response) = try await urlSession.data(for: request)
                    guard let http = response as? HTTPURLResponse else {
                        throw XetDownloaderError.invalidTokenResponse(underlying: nil)
                    }
                    guard (200 ..< 300).contains(http.statusCode) else {
                        throw XetDownloaderError.tokenRequestFailed(
                            statusCode: http.statusCode,
                            body: data
                        )
                    }

                    if let headerConnectionInfo = try Self.connectionInfo(from: http) {
                        return headerConnectionInfo
                    }

                    return try Self.connectionInfo(fromJSON: data)
                } catch {
                    guard Self.isRetryableTokenError(error) else {
                        throw error
                    }
                    lastError = error
                }
            }

            throw lastError ?? XetDownloaderError.invalidTokenResponse(underlying: nil)
        }

        private static func isRetryableTokenError(_ error: Error) -> Bool {
            if case let XetDownloaderError.tokenRequestFailed(statusCode, _) = error {
                return statusCode == 408 || statusCode == 429 || statusCode >= 500
            }

            if let urlError = error as? URLError {
                switch urlError.code {
                case .timedOut, .networkConnectionLost, .notConnectedToInternet,
                    .cannotConnectToHost, .dnsLookupFailed,
                    .internationalRoamingOff, .dataNotAllowed,
                    .cannotParseResponse:
                    return true
                default:
                    return false
                }
            }

            return false
        }

        private static func connectionInfo(from response: HTTPURLResponse) throws -> ConnectionInfo? {
            guard
                let casURLString = response.value(forHTTPHeaderField: "X-Xet-Cas-Url"),
                let accessToken = response.value(forHTTPHeaderField: "X-Xet-Access-Token"),
                let expirationString = response.value(forHTTPHeaderField: "X-Xet-Token-Expiration"),
                let expiration = Int(expirationString)
            else {
                return nil
            }
            guard let casURL = URL(string: casURLString) else {
                throw XetDownloaderError.invalidCASURL(casURLString)
            }
            let expiresAt = Date(timeIntervalSince1970: TimeInterval(expiration))
            try validateExpiration(expiresAt)
            return ConnectionInfo(
                casURL: casURL,
                accessToken: accessToken,
                expiresAt: expiresAt
            )
        }

        private static func connectionInfo(fromJSON data: Data) throws -> ConnectionInfo {
            let decoded: TokenResponse
            do {
                decoded = try JSONDecoder().decode(TokenResponse.self, from: data)
            } catch {
                throw XetDownloaderError.invalidTokenResponse(underlying: error)
            }
            guard let casURL = URL(string: decoded.casUrl) else {
                throw XetDownloaderError.invalidCASURL(decoded.casUrl)
            }
            let expiresAt = Date(timeIntervalSince1970: TimeInterval(decoded.exp))
            try validateExpiration(expiresAt)
            return ConnectionInfo(
                casURL: casURL,
                accessToken: decoded.accessToken,
                expiresAt: expiresAt
            )
        }

        // The token endpoint occasionally returns expirations that are already
        // in the past (server clock skew, misconfigured token length). Without
        // this check we would accept the token, fail it as expired in the
        // cache lookup, and refresh in a tight loop until something else broke.
        private static func validateExpiration(_ expiresAt: Date) throws {
            guard expiresAt > Date() else {
                throw XetDownloaderError.invalidTokenResponse(underlying: nil)
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
private struct FetchRangeKey: Hashable, Sendable {
    let hash: String
    let chunkRanges: [Range<Int>]
    let urlRanges: [ClosedRange<UInt64>]

    init(
        hash: String,
        fetchInfo: CASClient.ReconstructionResponse.FetchInfo
    ) {
        self.hash = hash
        self.chunkRanges = fetchInfo.ranges.map(\.chunkRange)
        self.urlRanges = fetchInfo.ranges.map(\.urlRange)
    }

    func matches(fetchInfo: CASClient.ReconstructionResponse.FetchInfo) -> Bool {
        chunkRanges == fetchInfo.ranges.map(\.chunkRange)
            && urlRanges == fetchInfo.ranges.map(\.urlRange)
    }
}

/// A fetched xorb chunk.
private struct FetchedXorb: Sendable {
    let data: Data
    let chunkByteIndices: [Int]
    let chunkRanges: [Range<Int>]

    func flattenedBoundaryIndex(forChunkBoundary chunkBoundary: Int) -> Int {
        var flattenedIndex = 0
        for range in chunkRanges {
            if chunkBoundary >= range.lowerBound, chunkBoundary <= range.upperBound {
                return flattenedIndex + (chunkBoundary - range.lowerBound)
            }
            flattenedIndex += range.count
        }
        return -1
    }
}

enum MultipartByteRanges {
    struct Part {
        let range: ClosedRange<UInt64>
        let data: Data
    }

    static func parse(contentType: String, body: Data) throws -> [Part] {
        let boundary = try boundary(from: contentType)
        let firstDelimiter = Data("--\(boundary)".utf8)
        let delimiter = Data("\r\n--\(boundary)".utf8)
        let bodyBytes = [UInt8](body)
        let firstDelimiterBytes = [UInt8](firstDelimiter)
        let delimiterBytes = [UInt8](delimiter)

        guard let firstStart = bodyBytes.firstRange(of: firstDelimiterBytes)?.lowerBound else {
            throw XetDownloaderError.invalidReconstructionResponse
        }

        var cursor = firstStart + firstDelimiterBytes.count
        var parts: [Part] = []
        while cursor + 2 <= bodyBytes.count, bodyBytes[cursor ..< cursor + 2].elementsEqual([13, 10]) {
            cursor += 2
            let partStart = cursor
            let nextBoundary = bodyBytes[partStart...].firstRange(of: delimiterBytes)?.lowerBound ?? bodyBytes.count
            let partBytes = Array(bodyBytes[partStart ..< nextBoundary])
            guard let separator = partBytes.firstRange(of: [13, 10, 13, 10]) else {
                throw XetDownloaderError.invalidReconstructionResponse
            }

            let headers = Data(partBytes[..<separator.lowerBound])
            let dataStart = separator.upperBound
            let range = try contentRange(from: headers)
            let data = Data(partBytes[dataStart...])
            parts.append(Part(range: range, data: data))

            cursor = nextBoundary + delimiterBytes.count
        }

        return parts.sorted { $0.range.lowerBound < $1.range.lowerBound }
    }

    private static func boundary(from contentType: String) throws -> String {
        for part in contentType.split(separator: ";") {
            let trimmed = part.trimmingCharacters(in: .whitespacesAndNewlines)
            if let value = trimmed.dropPrefix("boundary=") {
                return String(value).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            }
        }
        throw XetDownloaderError.invalidReconstructionResponse
    }

    private static func contentRange(from headers: Data) throws -> ClosedRange<UInt64> {
        guard let headerString = String(data: headers, encoding: .utf8) else {
            throw XetDownloaderError.invalidReconstructionResponse
        }
        for line in headerString.components(separatedBy: "\r\n") {
            guard let value = line.dropCaseInsensitivePrefix("Content-Range:") else {
                continue
            }
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.hasPrefix("bytes ") else {
                continue
            }
            let rangeAndSize = trimmed.dropFirst("bytes ".count)
            guard
                let slash = rangeAndSize.firstIndex(of: "/"),
                let dash = rangeAndSize[..<slash].firstIndex(of: "-"),
                let start = UInt64(rangeAndSize[..<dash]),
                let end = UInt64(rangeAndSize[rangeAndSize.index(after: dash) ..< slash])
            else {
                throw XetDownloaderError.invalidReconstructionResponse
            }
            return start ... end
        }
        throw XetDownloaderError.invalidReconstructionResponse
    }
}

private extension String {
    func dropPrefix(_ prefix: String) -> Substring? {
        guard hasPrefix(prefix) else { return nil }
        return dropFirst(prefix.count)
    }

    func dropCaseInsensitivePrefix(_ prefix: String) -> Substring? {
        guard lowercased().hasPrefix(prefix.lowercased()) else { return nil }
        return dropFirst(prefix.count)
    }
}

private extension Collection where Element == UInt8, Index == Int {
    func firstRange(of needle: [UInt8]) -> Range<Int>? {
        guard !needle.isEmpty, needle.count <= count else { return nil }
        var index = startIndex
        while index <= endIndex - needle.count {
            let candidate = index ..< index + needle.count
            if self[candidate].elementsEqual(needle) {
                return candidate
            }
            formIndex(after: &index)
        }
        return nil
    }
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
    private let url: URL
    private let baseOffset: Int64
    private var sequentialOffset: Int64 = 0

    init(destinationURL: URL, appendOffset: Int64? = nil) throws {
        // The caller (`XetDownloader.download(_:byteRange:to:fileManager:appendingToExistingFile:)`)
        // is responsible for ensuring the destination is in the expected state:
        // either absent/empty (when `appendOffset == nil`) or exactly
        // `appendOffset` bytes long.
        let flags = appendOffset == nil ? O_CREAT | O_RDWR | O_TRUNC : O_CREAT | O_RDWR
        let mode: mode_t = S_IRUSR | S_IWUSR | S_IRGRP | S_IROTH
        let fd = open(destinationURL.path, flags, mode)
        if fd < 0 {
            throw XetDownloaderError.fileOperationFailed(
                operation: "open",
                url: destinationURL,
                underlying: POSIXError(POSIXError.Code(rawValue: errno) ?? .EIO)
            )
        }
        self.fd = fd
        self.url = destinationURL
        self.baseOffset = appendOffset ?? 0
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
            throw XetDownloaderError.fileOperationFailed(
                operation: "write",
                url: url,
                underlying: POSIXError(.EBADF)
            )
        }
        var bytesRemaining = buffer.count
        var localOffset = 0
        while bytesRemaining > 0 {
            let writeSize = bytesRemaining
            let written = pwrite(
                currentFD,
                baseAddress.advanced(by: localOffset),
                writeSize,
                off_t(baseOffset + offset + Int64(localOffset))
            )
            if written < 0 {
                throw XetDownloaderError.fileOperationFailed(
                    operation: "write",
                    url: url,
                    underlying: POSIXError(POSIXError.Code(rawValue: errno) ?? .EIO)
                )
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
            throw XetDownloaderError.fileOperationFailed(
                operation: "close",
                url: url,
                underlying: POSIXError(POSIXError.Code(rawValue: errno) ?? .EIO)
            )
        }
    }
}
