import Foundation
#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif
import Testing

@testable import Xet

typealias ReconstructionResponse = CASClient.ReconstructionResponse

private final class CASMockURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?
    nonisolated(unsafe) static var requests: [URLRequest] = []

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        do {
            Self.requests.append(request)
            let (response, data) = try Self.handler?(request) ?? {
                let response = HTTPURLResponse(
                    url: request.url!,
                    statusCode: 500,
                    httpVersion: nil,
                    headerFields: nil
                )!
                return (response, Data())
            }()
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

@Suite("CAS Tests", .serialized)
struct CASTests {
    private func makeClient() -> CASClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CASMockURLProtocol.self]
        return CASClient(urlSession: URLSession(configuration: configuration))
    }

    private func resetMock() {
        CASMockURLProtocol.handler = nil
        CASMockURLProtocol.requests = []
    }

    // MARK: - ReconstructionResponse Codable

    @Test func reconstructionResponseDecodesFromJSON() throws {
        let json = """
            {
                "offset_into_first_range": 100,
                "terms": [
                    {
                        "hash": "abc123",
                        "unpacked_length": 1024,
                        "range": {"start": 0, "end": 5}
                    },
                    {
                        "hash": "def456",
                        "unpacked_length": 2048,
                        "range": {"start": 0, "end": 3}
                    }
                ],
                "fetch_info": {
                    "abc123": [
                        {
                            "url": "https://example.com/xorb1",
                            "range": {"start": 0, "end": 10},
                            "url_range": {"start": 0, "end": 999}
                        }
                    ],
                    "def456": [
                        {
                            "url": "https://example.com/xorb2",
                            "range": {"start": 0, "end": 5},
                            "url_range": {"start": 1000, "end": 1999}
                        }
                    ]
                }
            }
            """

        let response = try JSONDecoder().decode(
            ReconstructionResponse.self,
            from: Data(json.utf8)
        )

        #expect(response.offsetIntoFirstRange == 100)
        #expect(response.terms.count == 2)

        let term0 = response.terms[0]
        #expect(term0.hash == "abc123")
        #expect(term0.unpackedLength == 1024)
        #expect(term0.range == 0 ..< 5)

        let term1 = response.terms[1]
        #expect(term1.hash == "def456")
        #expect(term1.unpackedLength == 2048)
        #expect(term1.range == 0 ..< 3)

        #expect(response.fetchInfo.count == 2)

        let fetchInfo0 = response.fetchInfo["abc123"]!.first!
        #expect(fetchInfo0.url == "https://example.com/xorb1")
        #expect(fetchInfo0.range == 0 ..< 10)
        #expect(fetchInfo0.urlRange == 0 ... 999)

        let fetchInfo1 = response.fetchInfo["def456"]!.first!
        #expect(fetchInfo1.url == "https://example.com/xorb2")
        #expect(fetchInfo1.range == 0 ..< 5)
        #expect(fetchInfo1.urlRange == 1000 ... 1999)
    }

    @Test func reconstructionResponseEncodesToJSON() throws {
        let response = ReconstructionResponse(
            offsetIntoFirstRange: 50,
            terms: [
                .init(hash: "hash1", unpackedLength: 512, range: 0 ..< 3)
            ],
            fetchInfo: [
                "hash1": [
                    .init(url: "https://cdn.example/blob", range: 0 ..< 3, urlRange: 100 ... 500)
                ]
            ]
        )

        let data = try JSONEncoder().encode(response)
        let decoded = try JSONDecoder().decode(ReconstructionResponse.self, from: data)

        #expect(decoded.offsetIntoFirstRange == response.offsetIntoFirstRange)
        #expect(decoded.terms.count == response.terms.count)
        #expect(decoded.terms[0].hash == response.terms[0].hash)
        #expect(decoded.terms[0].range == response.terms[0].range)
        #expect(decoded.fetchInfo["hash1"]!.first!.urlRange == 100 ... 500)
    }

    @Test func termDecodesSnakeCaseFields() throws {
        let json = """
            {
                "hash": "somehash",
                "unpacked_length": 4096,
                "range": {"start": 5, "end": 10}
            }
            """

        let term = try JSONDecoder().decode(
            ReconstructionResponse.Term.self,
            from: Data(json.utf8)
        )

        #expect(term.hash == "somehash")
        #expect(term.unpackedLength == 4096)
        #expect(term.range == 5 ..< 10)
    }

    @Test func fetchInfoDecodesNestedRanges() throws {
        let json = """
            {
                "url": "https://storage.example/file",
                "range": {"start": 0, "end": 100},
                "url_range": {"start": 1000, "end": 2000}
            }
            """

        let fetchInfo = try JSONDecoder().decode(
            ReconstructionResponse.FetchInfo.self,
            from: Data(json.utf8)
        )

        #expect(fetchInfo.url == "https://storage.example/file")
        #expect(fetchInfo.range == 0 ..< 100)
        #expect(fetchInfo.urlRange == 1000 ... 2000)
    }

    @Test func fetchInfoURLRangeHeaderValue() throws {
        let fetchInfo = ReconstructionResponse.FetchInfo(
            url: "https://example.com",
            range: 0 ..< 5,
            urlRange: 100 ... 500
        )

        #expect(fetchInfo.urlRangeHeaderValue == "bytes=100-500")
    }

    // MARK: - Edge Cases

    @Test func emptyTermsArray() throws {
        let json = """
            {
                "offset_into_first_range": 0,
                "terms": [],
                "fetch_info": {}
            }
            """

        let response = try JSONDecoder().decode(
            ReconstructionResponse.self,
            from: Data(json.utf8)
        )

        #expect(response.offsetIntoFirstRange == 0)
        #expect(response.terms.isEmpty)
        #expect(response.fetchInfo.isEmpty)
    }

    @Test func multipleFetchInfosForSameHash() throws {
        let json = """
            {
                "offset_into_first_range": 0,
                "terms": [],
                "fetch_info": {
                    "hash1": [
                        {"url": "url1", "range": {"start": 0, "end": 5}, "url_range": {"start": 0, "end": 100}},
                        {"url": "url2", "range": {"start": 5, "end": 10}, "url_range": {"start": 100, "end": 200}}
                    ]
                }
            }
            """

        let response = try JSONDecoder().decode(
            ReconstructionResponse.self,
            from: Data(json.utf8)
        )

        #expect(response.fetchInfo["hash1"]?.count == 2)
        #expect(response.fetchInfo["hash1"]?[0].url == "url1")
        #expect(response.fetchInfo["hash1"]?[1].url == "url2")
    }

    @Test func largeOffsetValue() throws {
        let json = """
            {
                "offset_into_first_range": 18446744073709551615,
                "terms": [],
                "fetch_info": {}
            }
            """

        let response = try JSONDecoder().decode(
            ReconstructionResponse.self,
            from: Data(json.utf8)
        )

        #expect(response.offsetIntoFirstRange == UInt64.max)
    }

    @Test func rangeWithZeroLength() throws {
        let term = ReconstructionResponse.Term(
            hash: "empty",
            unpackedLength: 0,
            range: 5 ..< 5  // empty range
        )

        #expect(term.range.isEmpty)
        #expect(term.range.lowerBound == 5)
        #expect(term.range.upperBound == 5)
    }

    // MARK: - CAS API behavior

    @Test func reconstructionUsesV2ResponseShape() async throws {
        resetMock()
        defer { resetMock() }

        CASMockURLProtocol.handler = { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            )!
            let body = Data(
                """
                {
                    "offset_into_first_range": 0,
                    "terms": [
                        {
                            "hash": "xorbhash",
                            "unpacked_length": 1024,
                            "range": {"start": 0, "end": 2}
                        }
                    ],
                    "xorbs": {
                        "xorbhash": [
                            {
                                "url": "https://cdn.example/xorb",
                                "ranges": [
                                    {
                                        "chunks": {"start": 0, "end": 2},
                                        "bytes": {"start": 10, "end": 99}
                                    }
                                ]
                            }
                        ]
                    }
                }
                """.utf8
            )
            return (response, body)
        }

        let optionalResponse = try await makeClient().reconstruction(
            of: String(repeating: "a", count: 64),
            casURL: URL(string: "https://cas-v2.example")!,
            accessToken: "token",
            requestHeaders: ["User-Agent": "swift-xet-test"],
            byteRange: 5 ..< 10,
            maxRetries: 0
        )
        let response = try #require(optionalResponse)

        #expect(CASMockURLProtocol.requests.count == 1)
        #expect(CASMockURLProtocol.requests[0].url?.path == "/v2/reconstructions/\(String(repeating: "a", count: 64))")
        #expect(CASMockURLProtocol.requests[0].value(forHTTPHeaderField: "Range") == "bytes=5-9")
        #expect(CASMockURLProtocol.requests[0].value(forHTTPHeaderField: "Authorization") == "Bearer token")
        #expect(CASMockURLProtocol.requests[0].value(forHTTPHeaderField: "User-Agent") == "swift-xet-test")
        #expect(response.fetchInfo["xorbhash"]?.first?.urlRangeHeaderValue == "bytes=10-99")
    }

    @Test func reconstructionFallsBackToV1WhenV2Unavailable() async throws {
        resetMock()
        defer { resetMock() }

        CASMockURLProtocol.handler = { request in
            if request.url?.path.contains("/v2/") == true {
                let response = HTTPURLResponse(
                    url: request.url!,
                    statusCode: 501,
                    httpVersion: nil,
                    headerFields: nil
                )!
                return (response, Data())
            }

            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            )!
            let body = Data(
                """
                {
                    "offset_into_first_range": 0,
                    "terms": [],
                    "fetch_info": {}
                }
                """.utf8
            )
            return (response, body)
        }

        _ = try await makeClient().reconstruction(
            of: String(repeating: "b", count: 64),
            casURL: URL(string: "https://cas-v1-fallback.example")!,
            accessToken: "token",
            byteRange: nil,
            maxRetries: 2
        )

        #expect(CASMockURLProtocol.requests.map { $0.url?.path }.compactMap { $0 } == [
            "/v2/reconstructions/\(String(repeating: "b", count: 64))",
            "/v1/reconstructions/\(String(repeating: "b", count: 64))",
        ])
    }

    @Test func reconstructionRetriesTransientCASFailures() async throws {
        resetMock()
        defer { resetMock() }

        CASMockURLProtocol.handler = { request in
            if CASMockURLProtocol.requests.count == 1 {
                let response = HTTPURLResponse(
                    url: request.url!,
                    statusCode: 503,
                    httpVersion: nil,
                    headerFields: nil
                )!
                return (response, Data())
            }

            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            )!
            let body = Data(
                """
                {
                    "offset_into_first_range": 0,
                    "terms": [],
                    "xorbs": {}
                }
                """.utf8
            )
            return (response, body)
        }

        _ = try await makeClient().reconstruction(
            of: String(repeating: "c", count: 64),
            casURL: URL(string: "https://cas-retry.example")!,
            accessToken: "token",
            byteRange: nil,
            maxRetries: 1,
            retryBaseDelay: 0
        )

        #expect(CASMockURLProtocol.requests.count == 2)
    }

    @Test func reconstructionRetriesTruncatedJSONBodies() async throws {
        resetMock()
        defer { resetMock() }

        CASMockURLProtocol.handler = { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            )!

            if CASMockURLProtocol.requests.count == 1 {
                return (response, Data(#"{"offset_into_first_range":"#.utf8))
            }

            let body = Data(
                """
                {
                    "offset_into_first_range": 0,
                    "terms": [],
                    "xorbs": {}
                }
                """.utf8
            )
            return (response, body)
        }

        _ = try await makeClient().reconstruction(
            of: String(repeating: "e", count: 64),
            casURL: URL(string: "https://cas-json-retry.example")!,
            accessToken: "token",
            byteRange: nil,
            maxRetries: 1,
            retryBaseDelay: 0
        )

        #expect(CASMockURLProtocol.requests.count == 2)
    }

    @Test func reconstructionReturnsNilForExpected416() async throws {
        resetMock()
        defer { resetMock() }

        CASMockURLProtocol.handler = { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 416,
                httpVersion: nil,
                headerFields: nil
            )!
            return (response, Data())
        }

        let response = try await makeClient().reconstruction(
            of: String(repeating: "d", count: 64),
            casURL: URL(string: "https://cas-range-eof.example")!,
            accessToken: "token",
            byteRange: 100 ..< 200,
            maxRetries: 1,
            retryBaseDelay: 0
        )

        #expect(response == nil)
        #expect(CASMockURLProtocol.requests.count == 1)
    }
}
