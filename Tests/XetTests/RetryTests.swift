import Foundation
#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif
import Testing

@testable import Xet

@Suite("Retry Logic Tests")
struct RetryTests {

    // MARK: - Error classification

    @Test func serverErrorIsRetryable() {
        let error = XetDownloaderError.fetchFailed(statusCode: 500, url: URL(fileURLWithPath: "/"))
        #expect(XetDownloader.isRetryable(error))
    }

    @Test func badGatewayIsRetryable() {
        let error = XetDownloaderError.fetchFailed(statusCode: 502, url: URL(fileURLWithPath: "/"))
        #expect(XetDownloader.isRetryable(error))
    }

    @Test func serviceUnavailableIsRetryable() {
        let error = XetDownloaderError.fetchFailed(statusCode: 503, url: URL(fileURLWithPath: "/"))
        #expect(XetDownloader.isRetryable(error))
    }

    @Test func rateLimitIsRetryable() {
        let error = XetDownloaderError.fetchFailed(statusCode: 429, url: URL(fileURLWithPath: "/"))
        #expect(XetDownloader.isRetryable(error))
    }

    @Test func notFoundIsNotRetryable() {
        let error = XetDownloaderError.fetchFailed(statusCode: 404, url: URL(fileURLWithPath: "/"))
        #expect(!XetDownloader.isRetryable(error))
    }

    @Test func forbiddenIsNotRetryable() {
        let error = XetDownloaderError.fetchFailed(statusCode: 403, url: URL(fileURLWithPath: "/"))
        #expect(!XetDownloader.isRetryable(error))
    }

    @Test func badRequestIsNotRetryable() {
        let error = XetDownloaderError.fetchFailed(statusCode: 400, url: URL(fileURLWithPath: "/"))
        #expect(!XetDownloader.isRetryable(error))
    }

    @Test func fetchFailedWithNoStatusCodeIsNotRetryable() {
        let error = XetDownloaderError.fetchFailed(statusCode: nil, url: URL(fileURLWithPath: "/"))
        #expect(!XetDownloader.isRetryable(error))
    }

    @Test func timeoutIsRetryable() {
        let error = URLError(.timedOut)
        #expect(XetDownloader.isRetryable(error))
    }

    @Test func networkConnectionLostIsRetryable() {
        let error = URLError(.networkConnectionLost)
        #expect(XetDownloader.isRetryable(error))
    }

    @Test func notConnectedToInternetIsRetryable() {
        let error = URLError(.notConnectedToInternet)
        #expect(XetDownloader.isRetryable(error))
    }

    @Test func cannotConnectToHostIsRetryable() {
        let error = URLError(.cannotConnectToHost)
        #expect(XetDownloader.isRetryable(error))
    }

    @Test func dnsLookupFailedIsRetryable() {
        let error = URLError(.dnsLookupFailed)
        #expect(XetDownloader.isRetryable(error))
    }

    @Test func internationalRoamingOffIsRetryable() {
        let error = URLError(.internationalRoamingOff)
        #expect(XetDownloader.isRetryable(error))
    }

    @Test func dataNotAllowedIsRetryable() {
        let error = URLError(.dataNotAllowed)
        #expect(XetDownloader.isRetryable(error))
    }

    @Test func cancelledIsNotRetryable() {
        let error = URLError(.cancelled)
        #expect(!XetDownloader.isRetryable(error))
    }

    @Test func badURLIsNotRetryable() {
        let error = URLError(.badURL)
        #expect(!XetDownloader.isRetryable(error))
    }

    @Test func badServerResponseIsNotRetryable() {
        let error = URLError(.badServerResponse)
        #expect(!XetDownloader.isRetryable(error))
    }

    @Test func xorbErrorIsRetryable() {
        let error = XorbError.truncatedStream
        #expect(XetDownloader.isRetryable(error))
    }

    @Test func xorbDecompressionFailedIsRetryable() {
        let error = XorbError.decompressionFailed
        #expect(XetDownloader.isRetryable(error))
    }

    @Test func xorbLengthMismatchIsRetryable() {
        let error = XorbError.lengthMismatch(expected: 100, actual: 50)
        #expect(XetDownloader.isRetryable(error))
    }

    @Test func xorbInvalidLengthIsRetryable() {
        let error = XorbError.invalidLength
        #expect(XetDownloader.isRetryable(error))
    }

    @Test func xorbUnsupportedVersionIsNotRetryable() {
        let error = XorbError.unsupportedVersion(99)
        #expect(!XetDownloader.isRetryable(error))
    }

    @Test func xorbUnsupportedCompressionSchemeIsNotRetryable() {
        let error = XorbError.unsupportedCompressionScheme(99)
        #expect(!XetDownloader.isRetryable(error))
    }

    @Test func requestTimeoutIsRetryable() {
        let error = XetDownloaderError.fetchFailed(statusCode: 408, url: URL(fileURLWithPath: "/"))
        #expect(XetDownloader.isRetryable(error))
    }

    @Test func invalidFileIDIsNotRetryable() {
        let error = XetDownloaderError.invalidFileID("abc")
        #expect(!XetDownloader.isRetryable(error))
    }

    @Test func invalidReconstructionIsNotRetryable() {
        let error = XetDownloaderError.invalidReconstruction
        #expect(!XetDownloader.isRetryable(error))
    }

    @Test func arbitraryErrorIsNotRetryable() {
        struct CustomError: Error {}
        #expect(!XetDownloader.isRetryable(CustomError()))
    }

    // MARK: - Configuration defaults

    @Test func defaultRetryConfiguration() {
        let config = XetDownloader.Configuration.default
        #expect(config.maxRetryAttempts == 5)
        #expect(config.retryBaseDelay == 3)
        #expect(config.retryMaxDuration == 360)
    }

    @Test func retryDisabledWithOneAttempt() {
        var config = XetDownloader.Configuration.default
        config.maxRetryAttempts = 1
        #expect(config.maxRetryAttempts == 1)
    }
}
