import Foundation
import Testing

@testable import Xet

@Suite("MultipartByteRanges Parser Tests")
struct MultipartByteRangesTests {
    @Test func extractsBoundaryUnquoted() throws {
        let body = Data("--something\r\nContent-Range: bytes 0-3/100\r\n\r\nhi!!\r\n--something--\r\n".utf8)
        let parts = try MultipartByteRanges.parse(
            contentType: "multipart/byteranges; boundary=something",
            body: body
        )
        #expect(parts.count == 1)
        #expect(parts[0].range == 0 ... 3)
    }

    @Test func extractsBoundaryQuoted() throws {
        let body = Data("--quoted\r\nContent-Range: bytes 0-3/100\r\n\r\nhi!!\r\n--quoted--\r\n".utf8)
        let parts = try MultipartByteRanges.parse(
            contentType: "multipart/byteranges; boundary=\"quoted\"",
            body: body
        )
        #expect(parts.count == 1)
        #expect(parts[0].range == 0 ... 3)
    }

    @Test func missingBoundaryThrows() {
        let body = Data("anything".utf8)
        #expect(throws: XetDownloaderError.self) {
            _ = try MultipartByteRanges.parse(contentType: "text/plain", body: body)
        }
    }

    @Test func parsesSinglePart() throws {
        let boundary = "abc123"
        let body = Data(
            "--\(boundary)\r\nContent-Type: application/octet-stream\r\nContent-Range: bytes 0-99/1000\r\n\r\nHello World\r\n--\(boundary)--\r\n".utf8
        )
        let contentType = "multipart/byteranges; boundary=\(boundary)"

        let parts = try MultipartByteRanges.parse(contentType: contentType, body: body)
        #expect(parts.count == 1)
        #expect(parts[0].range.lowerBound == 0)
        #expect(parts[0].range.upperBound == 99)
        #expect(parts[0].data == Data("Hello World".utf8))
    }

    @Test func parsesMultipleParts() throws {
        let boundary = "sep"
        let body = Data(
            "--\(boundary)\r\nContent-Range: bytes 100-199/1000\r\n\r\nPart2Data\r\n--\(boundary)\r\nContent-Range: bytes 0-49/1000\r\n\r\nPart1Data\r\n--\(boundary)--\r\n".utf8
        )
        let contentType = "multipart/byteranges; boundary=\(boundary)"

        let parts = try MultipartByteRanges.parse(contentType: contentType, body: body)
        #expect(parts.count == 2)
        // Parts are sorted by range start.
        #expect(parts[0].range.lowerBound == 0)
        #expect(parts[0].range.upperBound == 49)
        #expect(parts[0].data == Data("Part1Data".utf8))
        #expect(parts[1].range.lowerBound == 100)
        #expect(parts[1].range.upperBound == 199)
        #expect(parts[1].data == Data("Part2Data".utf8))
    }

    @Test func emptyBodyThrows() {
        let contentType = "multipart/byteranges; boundary=xyz"
        #expect(throws: XetDownloaderError.self) {
            _ = try MultipartByteRanges.parse(contentType: contentType, body: Data())
        }
    }

    @Test func partMissingHeaderSeparatorThrows() {
        let boundary = "xyz"
        let body = Data(
            "--\(boundary)\r\nContent-Range: bytes 0-9/100\r\nMISSING_SEPARATOR\r\n--\(boundary)--\r\n".utf8
        )
        let contentType = "multipart/byteranges; boundary=\(boundary)"
        #expect(throws: XetDownloaderError.self) {
            _ = try MultipartByteRanges.parse(contentType: contentType, body: body)
        }
    }
}
