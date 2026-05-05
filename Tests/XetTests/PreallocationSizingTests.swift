import Testing

@testable import Xet

@Suite("Preallocation Sizing Tests")
struct PreallocationSizingTests {
    @Test func returnsSizeWhenReferencesFullyCoverFetchedRange() {
        let result = XetDownloader.uncompressedSizeIfKnown(
            chunkRanges: [0 ..< 3],
            references: [
                .init(chunkRange: 0 ..< 1, uncompressedSize: 10),
                .init(chunkRange: 1 ..< 2, uncompressedSize: 20),
                .init(chunkRange: 2 ..< 3, uncompressedSize: 30),
            ]
        )

        #expect(result == 60)
    }

    @Test func returnsNilWhenFetchRangeHasUnreferencedPrefix() {
        let result = XetDownloader.uncompressedSizeIfKnown(
            chunkRanges: [0 ..< 3],
            references: [
                .init(chunkRange: 1 ..< 2, uncompressedSize: 20),
                .init(chunkRange: 2 ..< 3, uncompressedSize: 30),
            ]
        )

        #expect(result == nil)
    }

    @Test func returnsNilWhenFetchRangeHasUnreferencedSuffix() {
        let result = XetDownloader.uncompressedSizeIfKnown(
            chunkRanges: [0 ..< 3],
            references: [
                .init(chunkRange: 0 ..< 1, uncompressedSize: 10),
                .init(chunkRange: 1 ..< 2, uncompressedSize: 20),
            ]
        )

        #expect(result == nil)
    }

    @Test func returnsNilWhenReferenceCoverageHasInternalGap() {
        let result = XetDownloader.uncompressedSizeIfKnown(
            chunkRanges: [0 ..< 4],
            references: [
                .init(chunkRange: 0 ..< 1, uncompressedSize: 10),
                .init(chunkRange: 2 ..< 4, uncompressedSize: 40),
            ]
        )

        #expect(result == nil)
    }

    @Test func bridgesGapsBetweenExplicitMultiRangeFetches() {
        let result = XetDownloader.uncompressedSizeIfKnown(
            chunkRanges: [0 ..< 2, 4 ..< 6],
            references: [
                .init(chunkRange: 0 ..< 1, uncompressedSize: 10),
                .init(chunkRange: 1 ..< 2, uncompressedSize: 20),
                .init(chunkRange: 4 ..< 5, uncompressedSize: 30),
                .init(chunkRange: 5 ..< 6, uncompressedSize: 40),
            ]
        )

        #expect(result == 100)
    }
}
