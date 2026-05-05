import Foundation
#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

/// Client for the Xet Content Addressable Storage (CAS) reconstruction API.
///
/// The CAS server stores file data as deduplicated, compressed chunks
/// organized into xorbs. This client fetches reconstruction metadata
/// that describes how to reassemble a file from its constituent chunks.
struct CASClient: Sendable {
    private let urlSession: URLSession
    private static let reconstructionVersionState = ReconstructionVersionState()

    /// Creates a CAS client with the specified URL session.
    init(urlSession: URLSession = .shared) {
        self.urlSession = urlSession
    }

    /// Fetches reconstruction metadata for a file.
    ///
    /// The reconstruction response contains:
    /// - An ordered list of terms, each referencing a chunk range within a xorb
    /// - Fetch info with presigned URLs for downloading xorb data
    /// - An offset for partial range requests
    ///
    /// - Parameters:
    ///   - fileID: The 64-character hex file identifier (Merkle hash).
    ///   - casURL: The CAS API base URL from token response.
    ///   - accessToken: The CAS access token.
    ///   - byteRange: Optional byte range for partial file reconstruction.
    ///
    /// - Returns: The reconstruction response with terms and fetch info.
    ///
    /// - Throws: ``XetDownloaderError`` if the request fails.
    func reconstruction(
        of fileID: String,
        casURL: URL,
        accessToken: String,
        requestHeaders: [String: String] = [:],
        byteRange: Range<UInt64>?,
        enableMultiRangeFetching: Bool = false,
        maxRetries: Int = 5,
        retryBaseDelay: TimeInterval = 3,
        retryMaxDuration: TimeInterval = 360
    ) async throws -> ReconstructionResponse? {
        let detectedVersion = await Self.reconstructionVersionState.detectedVersion(for: casURL)
        if detectedVersion == 1 {
            return try await requestReconstruction(
                of: fileID,
                casURL: casURL,
                accessToken: accessToken,
                requestHeaders: requestHeaders,
                byteRange: byteRange,
                apiVersion: 1,
                enableMultiRangeFetching: enableMultiRangeFetching,
                maxRetries: maxRetries,
                retryBaseDelay: retryBaseDelay,
                retryMaxDuration: retryMaxDuration
            )
        }

        do {
            let response = try await requestReconstruction(
                of: fileID,
                casURL: casURL,
                accessToken: accessToken,
                requestHeaders: requestHeaders,
                byteRange: byteRange,
                apiVersion: 2,
                enableMultiRangeFetching: enableMultiRangeFetching,
                maxRetries: maxRetries,
                retryBaseDelay: retryBaseDelay,
                retryMaxDuration: retryMaxDuration
            )
            await Self.reconstructionVersionState.setDetectedVersion(2, for: casURL)
            return response
        } catch {
            guard detectedVersion == nil, Self.shouldFallbackToV1(error) else {
                throw error
            }
        }

        let response = try await requestReconstruction(
            of: fileID,
            casURL: casURL,
            accessToken: accessToken,
            requestHeaders: requestHeaders,
            byteRange: byteRange,
            apiVersion: 1,
            enableMultiRangeFetching: enableMultiRangeFetching,
            maxRetries: maxRetries,
            retryBaseDelay: retryBaseDelay,
            retryMaxDuration: retryMaxDuration
        )
        await Self.reconstructionVersionState.setDetectedVersion(1, for: casURL)
        return response
    }

    private func requestReconstruction(
        of fileID: String,
        casURL: URL,
        accessToken: String,
        requestHeaders: [String: String],
        byteRange: Range<UInt64>?,
        apiVersion: Int,
        enableMultiRangeFetching: Bool,
        maxRetries: Int,
        retryBaseDelay: TimeInterval,
        retryMaxDuration: TimeInterval
    ) async throws -> ReconstructionResponse? {
        let versionPath = "v\(apiVersion)"
        let url = casURL.appendingPathComponent(versionPath).appendingPathComponent("reconstructions")
            .appendingPathComponent(fileID)

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        for (key, value) in requestHeaders where key.caseInsensitiveCompare("authorization") != .orderedSame {
            request.setValue(value, forHTTPHeaderField: key)
        }
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        if let byteRange, !byteRange.isEmpty {
            request.setValue(byteRange.httpRangeHeaderValue, forHTTPHeaderField: "Range")
        }

        return try await reconstructionWithRetry(
            for: request,
            apiVersion: apiVersion,
            enableMultiRangeFetching: enableMultiRangeFetching,
            maxRetries: maxRetries,
            retryBaseDelay: retryBaseDelay,
            retryMaxDuration: retryMaxDuration
        )
    }

    private func reconstructionWithRetry(
        for request: URLRequest,
        apiVersion: Int,
        enableMultiRangeFetching: Bool,
        maxRetries: Int,
        retryBaseDelay: TimeInterval,
        retryMaxDuration: TimeInterval
    ) async throws -> ReconstructionResponse? {
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
                    throw XetDownloaderError.invalidReconstructionResponse
                }
                guard (200 ..< 300).contains(http.statusCode) else {
                    if http.statusCode == 416 {
                        return nil
                    }
                    throw XetDownloaderError.reconstructionRequestFailed(
                        statusCode: http.statusCode,
                        body: data
                    )
                }
                return try decodeReconstruction(
                    data,
                    apiVersion: apiVersion,
                    enableMultiRangeFetching: enableMultiRangeFetching
                )
            } catch {
                guard Self.isRetryableReconstructionError(error) else {
                    throw error
                }
                lastError = error
            }
        }

        throw lastError ?? XetDownloaderError.invalidReconstructionResponse
    }

    private func decodeReconstruction(
        _ data: Data,
        apiVersion: Int,
        enableMultiRangeFetching: Bool
    ) throws -> ReconstructionResponse {
        do {
            if apiVersion == 2 {
                let response = try JSONDecoder().decode(ReconstructionResponseV2.self, from: data)
                return try response.asReconstructionResponse(enableMultiRangeFetching: enableMultiRangeFetching)
            }
            return try JSONDecoder().decode(ReconstructionResponse.self, from: data)
        } catch {
            throw XetDownloaderError.reconstructionDecodingFailed(error)
        }
    }

    private static func shouldFallbackToV1(_ error: Error) -> Bool {
        if case let XetDownloaderError.reconstructionRequestFailed(statusCode, _) = error {
            return statusCode == 404 || statusCode == 501
        }
        return false
    }

    private static func isRetryableReconstructionError(_ error: Error) -> Bool {
        if case let XetDownloaderError.reconstructionRequestFailed(statusCode, _) = error {
            if statusCode == 501 {
                return false
            }
            return statusCode == 408 || statusCode == 429 || statusCode >= 500
        }

        if case let XetDownloaderError.reconstructionDecodingFailed(error) = error {
            return isLikelyTruncatedJSON(error)
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

    private static func isLikelyTruncatedJSON(_ error: Error) -> Bool {
        guard let decodingError = error as? DecodingError else {
            return false
        }
        let context: DecodingError.Context
        switch decodingError {
        case let .dataCorrupted(c):
            context = c
        case .keyNotFound, .typeMismatch, .valueNotFound:
            // These indicate schema mismatches (well-formed JSON missing fields,
            // wrong types). Retrying will not change the outcome.
            return false
        @unknown default:
            return false
        }

        // Foundation's JSONDecoder wraps the JSONSerialization parse error in
        // `context.underlyingError`. Truncated/malformed JSON surfaces as
        // NSCocoaErrorDomain code 3840 (propertyListReadCorrupt).
        if let underlying = context.underlyingError as NSError?,
            underlying.domain == NSCocoaErrorDomain,
            underlying.code == 3840
        {
            return true
        }

        // Fallback for platforms (notably swift-corelibs-foundation) where
        // the underlying error may not be reported with the canonical code.
        // Linux Foundation reports both truncated and malformed JSON with the
        // generic "The given data was not valid JSON." message and no
        // underlying error, so match that here as well.
        let lowercased = context.debugDescription.lowercased()
        return lowercased.contains("end of file")
            || lowercased.contains("eof")
            || lowercased.contains("unexpected end")
            || lowercased.contains("not valid json")
    }

    /// Response from the CAS reconstruction API.
    ///
    /// Describes how to reassemble a file from chunks stored across one or more xorbs.
    /// The file is reconstructed by processing terms in order,
    /// fetching the referenced chunk ranges,
    /// and concatenating the decompressed results.
    struct ReconstructionResponse: Codable, Sendable {
        /// Byte offset to skip in the first term's output.
        ///
        /// For full file downloads this is always 0.
        /// For range requests, indicates where the requested range starts
        /// within the first chunk's decompressed data.
        let offsetIntoFirstRange: UInt64

        /// Ordered list of terms describing chunks to fetch.
        ///
        /// Each term references a contiguous range of chunks within a xorb.
        /// Terms must be processed in order to reconstruct the file correctly.
        let terms: [Term]

        /// Fetch info keyed by xorb hash.
        ///
        /// Maps xorb hashes to arrays of fetch info,
        /// each providing a presigned URL and byte range for downloading chunk data.
        let fetchInfo: [String: [FetchInfo]]

        /// Creates a reconstruction response.
        init(offsetIntoFirstRange: UInt64, terms: [Term], fetchInfo: [String: [FetchInfo]]) {
            self.offsetIntoFirstRange = offsetIntoFirstRange
            self.terms = terms
            self.fetchInfo = fetchInfo
        }

        private enum CodingKeys: String, CodingKey {
            case offsetIntoFirstRange = "offset_into_first_range"
            case terms
            case fetchInfo = "fetch_info"
        }

        private enum RangeCodingKeys: String, CodingKey {
            case start
            case end
        }

        /// A reconstruction term referencing chunks within a xorb.
        ///
        /// Each term specifies which chunks to extract from a particular xorb.
        /// The `hash` identifies the xorb,
        /// and the `range` specifies the half-open interval of chunk indices.
        struct Term: Codable, Sendable {
            /// The xorb's 64-character hex hash.
            let hash: String

            /// Expected total bytes after decompressing all chunks in this term.
            let unpackedLength: UInt32

            /// Half-open range of chunk indices: `[start, end)`.
            let range: Range<Int>

            /// Creates a term.
            init(hash: String, unpackedLength: UInt32, range: Range<Int>) {
                self.hash = hash
                self.unpackedLength = unpackedLength
                self.range = range
            }

            private enum CodingKeys: String, CodingKey {
                case hash
                case unpackedLength = "unpacked_length"
                case range
            }

            public init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                hash = try container.decode(String.self, forKey: .hash)
                unpackedLength = try container.decode(UInt32.self, forKey: .unpackedLength)

                let rangeContainer = try container.nestedContainer(
                    keyedBy: RangeCodingKeys.self,
                    forKey: .range
                )
                let start = try rangeContainer.decode(Int.self, forKey: .start)
                let end = try rangeContainer.decode(Int.self, forKey: .end)
                range = start ..< end
            }

            public func encode(to encoder: Encoder) throws {
                var container = encoder.container(keyedBy: CodingKeys.self)
                try container.encode(hash, forKey: .hash)
                try container.encode(unpackedLength, forKey: .unpackedLength)

                var rangeContainer = container.nestedContainer(
                    keyedBy: RangeCodingKeys.self,
                    forKey: .range
                )
                try rangeContainer.encode(range.lowerBound, forKey: .start)
                try rangeContainer.encode(range.upperBound, forKey: .end)
            }
        }

        /// Information for fetching chunk data from a xorb.
        ///
        /// Provides a presigned URL and byte range for downloading
        /// a contiguous sequence of compressed chunks.
        struct FetchInfo: Codable, Sendable {
            /// Presigned URL for downloading xorb data.
            let url: String

            /// Chunk and byte ranges covered by this fetch.
            let ranges: [RangeDescriptor]

            /// Half-open range of chunk indices covered by this fetch.
            var range: Range<Int> {
                let lower = ranges.first?.chunkRange.lowerBound ?? 0
                let upper = ranges.last?.chunkRange.upperBound ?? lower
                return lower ..< upper
            }

            /// Closed byte range to request via HTTP `Range` header.
            var urlRange: ClosedRange<UInt64> {
                ranges.first?.urlRange ?? 0 ... 0
            }

            /// Closed byte ranges to request via HTTP `Range` header.
            var urlRanges: [ClosedRange<UInt64>] {
                ranges.map(\.urlRange)
            }

            /// Creates fetch info.
            init(url: String, range: Range<Int>, urlRange: ClosedRange<UInt64>) {
                self.url = url
                self.ranges = [
                    RangeDescriptor(chunkRange: range, urlRange: urlRange)
                ]
            }

            /// Creates fetch info from one or more range descriptors.
            init(url: String, ranges: [RangeDescriptor]) {
                precondition(!ranges.isEmpty)
                self.url = url
                self.ranges = ranges
            }

            /// Returns true when this fetch covers the entire term chunk range.
            func contains(termRange: Range<Int>) -> Bool {
                ranges.contains { descriptor in
                    descriptor.chunkRange.lowerBound <= termRange.lowerBound
                        && descriptor.chunkRange.upperBound >= termRange.upperBound
                }
            }

            /// The HTTP `Range` header value for this fetch.
            var urlRangeHeaderValue: String {
                let ranges = urlRanges
                    .map { "\($0.lowerBound)-\($0.upperBound)" }
                    .joined(separator: ",")
                return "bytes=\(ranges)"
            }

            private enum CodingKeys: String, CodingKey {
                case url
                case range
                case urlRange = "url_range"
            }

            public init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                url = try container.decode(String.self, forKey: .url)

                let rangeContainer = try container.nestedContainer(
                    keyedBy: RangeCodingKeys.self,
                    forKey: .range
                )
                let rangeStart = try rangeContainer.decode(Int.self, forKey: .start)
                let rangeEnd = try rangeContainer.decode(Int.self, forKey: .end)

                let urlRangeContainer = try container.nestedContainer(
                    keyedBy: RangeCodingKeys.self,
                    forKey: .urlRange
                )
                let urlStart = try urlRangeContainer.decode(UInt64.self, forKey: .start)
                let urlEnd = try urlRangeContainer.decode(UInt64.self, forKey: .end)
                ranges = [
                    RangeDescriptor(chunkRange: rangeStart ..< rangeEnd, urlRange: urlStart ... urlEnd)
                ]
            }

            public func encode(to encoder: Encoder) throws {
                var container = encoder.container(keyedBy: CodingKeys.self)
                try container.encode(url, forKey: .url)

                var rangeContainer = container.nestedContainer(
                    keyedBy: RangeCodingKeys.self,
                    forKey: .range
                )
                try rangeContainer.encode(range.lowerBound, forKey: .start)
                try rangeContainer.encode(range.upperBound, forKey: .end)

                var urlRangeContainer = container.nestedContainer(
                    keyedBy: RangeCodingKeys.self,
                    forKey: .urlRange
                )
                try urlRangeContainer.encode(urlRange.lowerBound, forKey: .start)
                try urlRangeContainer.encode(urlRange.upperBound, forKey: .end)
            }
        }

        /// Mapping from a chunk range to the corresponding xorb byte range.
        struct RangeDescriptor: Sendable, Hashable {
            let chunkRange: Range<Int>
            let urlRange: ClosedRange<UInt64>
        }
    }

    /// V2 response from the CAS reconstruction API.
    private struct ReconstructionResponseV2: Decodable {
        let offsetIntoFirstRange: UInt64
        let terms: [ReconstructionResponse.Term]
        let xorbs: [String: [XorbMultiRangeFetch]]

        private enum CodingKeys: String, CodingKey {
            case offsetIntoFirstRange = "offset_into_first_range"
            case terms
            case xorbs
        }

        func asReconstructionResponse(enableMultiRangeFetching: Bool) throws -> ReconstructionResponse {
            var fetchInfo: [String: [ReconstructionResponse.FetchInfo]] = [:]
            for (hash, fetches) in xorbs {
                fetchInfo[hash] = try fetches.flatMap { fetch -> [ReconstructionResponse.FetchInfo] in
                    guard !fetch.ranges.isEmpty else {
                        throw XetDownloaderError.invalidReconstruction
                    }
                    if enableMultiRangeFetching {
                        let descriptors = try fetch.ranges.map { try $0.asRangeDescriptor() }
                        return [
                            ReconstructionResponse.FetchInfo(url: fetch.url, ranges: descriptors)
                        ]
                    }

                    return try fetch.ranges.map { range in
                        let descriptor = try range.asRangeDescriptor()
                        return ReconstructionResponse.FetchInfo(
                            url: fetch.url,
                            range: descriptor.chunkRange,
                            urlRange: descriptor.urlRange
                        )
                    }
                }
            }

            return ReconstructionResponse(
                offsetIntoFirstRange: offsetIntoFirstRange,
                terms: terms,
                fetchInfo: fetchInfo
            )
        }

        struct XorbMultiRangeFetch: Decodable {
            let url: String
            let ranges: [XorbRangeDescriptor]
        }

        struct XorbRangeDescriptor: Decodable {
            let chunks: ChunkRange
            let bytes: ByteRange

            func asRangeDescriptor() throws -> ReconstructionResponse.RangeDescriptor {
                guard chunks.end >= chunks.start else {
                    throw XetDownloaderError.invalidReconstruction
                }
                guard bytes.end >= bytes.start else {
                    throw XetDownloaderError.invalidReconstruction
                }
                return ReconstructionResponse.RangeDescriptor(
                    chunkRange: chunks.start ..< chunks.end,
                    urlRange: bytes.start ... bytes.end
                )
            }
        }

        struct ChunkRange: Decodable {
            let start: Int
            let end: Int
        }

        struct ByteRange: Decodable {
            let start: UInt64
            let end: UInt64
        }
    }
}

private actor ReconstructionVersionState {
    private var versionsByEndpoint: [URL: Int] = [:]

    func detectedVersion(for endpoint: URL) -> Int? {
        versionsByEndpoint[endpoint]
    }

    func setDetectedVersion(_ version: Int, for endpoint: URL) {
        versionsByEndpoint[endpoint] = version
    }
}

// MARK: -

extension Range<UInt64> {
    /// Formats the range as an HTTP `Range` header value.
    ///
    /// Uses the standard `bytes=start-end` format where end is inclusive.
    fileprivate var httpRangeHeaderValue: String {
        precondition(!isEmpty)
        return "bytes=\(lowerBound)-\(upperBound - 1)"
    }
}
