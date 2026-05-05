import Foundation
#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

import Testing

@testable import Xet

private final class TokenMockURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?
    nonisolated(unsafe) static var lastHeaders: [String: String]?
    nonisolated(unsafe) static var requestCount = 0

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        do {
            Self.requestCount += 1
            Self.lastHeaders = request.allHTTPHeaderFields
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

@Suite("TokenProvider Tests", .serialized)
struct TokenProviderTests {
    private func makeProvider() -> XetDownloader.TokenProvider {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [TokenMockURLProtocol.self]
        return XetDownloader.TokenProvider(
            urlSession: URLSession(configuration: configuration)
        )
    }

    @Test func parsesCanonicalHeaderResponse() async throws {
        defer {
            TokenMockURLProtocol.handler = nil
            TokenMockURLProtocol.lastHeaders = nil
            TokenMockURLProtocol.requestCount = 0
        }
        TokenMockURLProtocol.handler = { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: [
                    "X-Xet-Cas-Url": "https://cas.example.com",
                    "X-Xet-Access-Token": "xet-token",
                    "X-Xet-Token-Expiration": "2000000000",
                ]
            )!
            return (response, Data())
        }

        let info = try await makeProvider().connectionInfo(
            for: URL(string: "https://huggingface.co/api/models/test/repo/xet-read-token/main")!,
            hubToken: "hub-token",
            requestHeaders: ["User-Agent": "swift-xet-test"]
        )

        #expect(info.casURL == URL(string: "https://cas.example.com")!)
        #expect(info.accessToken == "xet-token")
        #expect(Int(info.expiresAt.timeIntervalSince1970) == 2_000_000_000)
        #expect(TokenMockURLProtocol.lastHeaders?["Authorization"] == "Bearer hub-token")
        #expect(TokenMockURLProtocol.lastHeaders?["User-Agent"] == "swift-xet-test")
    }

    @Test func fallsBackToJSONTokenResponse() async throws {
        defer {
            TokenMockURLProtocol.handler = nil
            TokenMockURLProtocol.lastHeaders = nil
            TokenMockURLProtocol.requestCount = 0
        }
        TokenMockURLProtocol.handler = { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            )!
            let body = Data(
                #"{"accessToken":"json-token","exp":2000000001,"casUrl":"https://json-cas.example.com"}"#.utf8
            )
            return (response, body)
        }

        let info = try await makeProvider().connectionInfo(
            for: URL(string: "https://huggingface.co/api/models/test/repo/xet-read-token/main")!,
            hubToken: nil
        )

        #expect(info.casURL == URL(string: "https://json-cas.example.com")!)
        #expect(info.accessToken == "json-token")
        #expect(Int(info.expiresAt.timeIntervalSince1970) == 2_000_000_001)
    }

    @Test func retriesTransientTokenRefreshFailures() async throws {
        defer {
            TokenMockURLProtocol.handler = nil
            TokenMockURLProtocol.lastHeaders = nil
            TokenMockURLProtocol.requestCount = 0
        }
        TokenMockURLProtocol.handler = { request in
            if TokenMockURLProtocol.requestCount == 1 {
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
                headerFields: [
                    "X-Xet-Cas-Url": "https://cas.example.com",
                    "X-Xet-Access-Token": "xet-token",
                    "X-Xet-Token-Expiration": "2000000000",
                ]
            )!
            return (response, Data())
        }

        let info = try await makeProvider().connectionInfo(
            for: URL(string: "https://huggingface.co/api/models/test/repo/xet-read-token/retry")!,
            hubToken: nil,
            maxRetries: 1,
            retryBaseDelay: 0
        )

        #expect(info.accessToken == "xet-token")
        #expect(TokenMockURLProtocol.requestCount == 2)
    }
}
