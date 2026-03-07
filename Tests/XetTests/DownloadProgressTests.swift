import Foundation
import Testing

@testable import Xet

@Suite("DownloadProgress Tests")
struct DownloadProgressTests {

    // MARK: - DownloadProgress struct

    @Test func fractionCompletedHalfway() {
        let progress = DownloadProgress(totalBytes: 1000, bytesWritten: 500)
        #expect(progress.fractionCompleted == 0.5)
    }

    @Test func fractionCompletedAtZero() {
        let progress = DownloadProgress(totalBytes: 1000, bytesWritten: 0)
        #expect(progress.fractionCompleted == 0.0)
    }

    @Test func fractionCompletedAtOne() {
        let progress = DownloadProgress(totalBytes: 1000, bytesWritten: 1000)
        #expect(progress.fractionCompleted == 1.0)
    }

    @Test func fractionCompletedWithZeroTotalBytes() {
        let progress = DownloadProgress(totalBytes: 0, bytesWritten: 0)
        #expect(progress.fractionCompleted == 0.0)
    }

    @Test func fractionCompletedClampsToOne() {
        let progress = DownloadProgress(totalBytes: 100, bytesWritten: 150)
        #expect(progress.fractionCompleted == 1.0)
    }

    @Test func fractionCompletedWithNegativeTotalBytes() {
        let progress = DownloadProgress(totalBytes: -100, bytesWritten: 50)
        #expect(progress.fractionCompleted == 0.0)
    }

    @Test func fractionCompletedWithLargeValues() {
        let total: Int64 = 10_000_000_000_000  // 10 TB
        let written: Int64 = 5_000_000_000_000
        let progress = DownloadProgress(totalBytes: total, bytesWritten: written)
        #expect(progress.fractionCompleted == 0.5)
    }

    @Test func equatable() {
        let a = DownloadProgress(totalBytes: 100, bytesWritten: 50)
        let b = DownloadProgress(totalBytes: 100, bytesWritten: 50)
        let c = DownloadProgress(totalBytes: 100, bytesWritten: 75)
        #expect(a == b)
        #expect(a != c)
    }

    // MARK: - totalExpectedBytes (production code)

    @Test func totalExpectedBytesFullDownload() {
        let terms: [CASClient.ReconstructionResponse.Term] = [
            .init(hash: "a", unpackedLength: 1024, range: 0..<5),
            .init(hash: "b", unpackedLength: 2048, range: 0..<3),
        ]
        let result = XetDownloader.totalExpectedBytes(
            terms: terms, offsetIntoFirstRange: 0, maxBytesToWrite: nil
        )
        #expect(result == 3072)
    }

    @Test func totalExpectedBytesWithOffset() {
        let terms: [CASClient.ReconstructionResponse.Term] = [
            .init(hash: "a", unpackedLength: 1024, range: 0..<5),
            .init(hash: "b", unpackedLength: 2048, range: 0..<3),
        ]
        let result = XetDownloader.totalExpectedBytes(
            terms: terms, offsetIntoFirstRange: 100, maxBytesToWrite: nil
        )
        #expect(result == 2972)
    }

    @Test func totalExpectedBytesWithByteRange() {
        let terms: [CASClient.ReconstructionResponse.Term] = [
            .init(hash: "a", unpackedLength: 1024, range: 0..<5),
            .init(hash: "b", unpackedLength: 2048, range: 0..<3),
        ]
        let result = XetDownloader.totalExpectedBytes(
            terms: terms, offsetIntoFirstRange: 100, maxBytesToWrite: 500
        )
        #expect(result == 500)
    }

    @Test func totalExpectedBytesWithByteRangeLargerThanFile() {
        let terms: [CASClient.ReconstructionResponse.Term] = [
            .init(hash: "a", unpackedLength: 1024, range: 0..<5),
        ]
        let result = XetDownloader.totalExpectedBytes(
            terms: terms, offsetIntoFirstRange: 0, maxBytesToWrite: 9999
        )
        #expect(result == 1024)
    }

    @Test func totalExpectedBytesEmptyTerms() {
        let result = XetDownloader.totalExpectedBytes(
            terms: [], offsetIntoFirstRange: 0, maxBytesToWrite: nil
        )
        #expect(result == 0)
    }

    @Test func totalExpectedBytesOffsetExceedsTotalClampsToZero() {
        let terms: [CASClient.ReconstructionResponse.Term] = [
            .init(hash: "a", unpackedLength: 100, range: 0..<1),
        ]
        let result = XetDownloader.totalExpectedBytes(
            terms: terms, offsetIntoFirstRange: 500, maxBytesToWrite: nil
        )
        #expect(result == 0)
    }

    @Test func totalExpectedBytesSingleTerm() {
        let terms: [CASClient.ReconstructionResponse.Term] = [
            .init(hash: "a", unpackedLength: 4096, range: 0..<1),
        ]
        let result = XetDownloader.totalExpectedBytes(
            terms: terms, offsetIntoFirstRange: 0, maxBytesToWrite: nil
        )
        #expect(result == 4096)
    }

    @Test func totalExpectedBytesManySmallTerms() {
        let terms = (0..<100).map { i in
            CASClient.ReconstructionResponse.Term(
                hash: "hash\(i)", unpackedLength: 64, range: 0..<1
            )
        }
        let result = XetDownloader.totalExpectedBytes(
            terms: terms, offsetIntoFirstRange: 0, maxBytesToWrite: nil
        )
        #expect(result == 6400)
    }

    @Test func totalExpectedBytesWithOffsetAndByteRange() {
        // offset = 200, total unpacked = 1000, adjusted = 800, maxBytes = 300
        let terms: [CASClient.ReconstructionResponse.Term] = [
            .init(hash: "a", unpackedLength: 500, range: 0..<5),
            .init(hash: "b", unpackedLength: 500, range: 0..<5),
        ]
        let result = XetDownloader.totalExpectedBytes(
            terms: terms, offsetIntoFirstRange: 200, maxBytesToWrite: 300
        )
        #expect(result == 300)
    }

    @Test func totalExpectedBytesWithOffsetAndByteRangeExceedingAdjusted() {
        // offset = 200, total unpacked = 1000, adjusted = 800, maxBytes = 900
        let terms: [CASClient.ReconstructionResponse.Term] = [
            .init(hash: "a", unpackedLength: 500, range: 0..<5),
            .init(hash: "b", unpackedLength: 500, range: 0..<5),
        ]
        let result = XetDownloader.totalExpectedBytes(
            terms: terms, offsetIntoFirstRange: 200, maxBytesToWrite: 900
        )
        #expect(result == 800)
    }
}
