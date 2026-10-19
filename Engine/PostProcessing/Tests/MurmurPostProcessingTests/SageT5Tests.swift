import XCTest
@testable import MurmurPostProcessing

final class SageT5Tests: XCTestCase {
    func testBidirectionalPositionsHaveSeparatePastAndFutureBuckets() {
        let bucket: (Int) -> Int = { SageT5.relativeBucket(distance: $0, bidirectional: true, buckets: 32, maximumDistance: 128) }
        XCTAssertEqual(bucket(0), 0)
        XCTAssertEqual(bucket(-1), 1)
        XCTAssertEqual(bucket(1), 17)
        XCTAssertEqual(bucket(-128), 15)
        XCTAssertEqual(bucket(128), 31)
        XCTAssertEqual(bucket(-100_000), 15)
    }
    func testCachedDecoderUsesAbsoluteQueryOffsetAndSaturatesDistantKeys() {
        let bucket: (Int) -> Int = { SageT5.relativeBucket(distance: $0, bidirectional: false, buckets: 32, maximumDistance: 128) }
        XCTAssertEqual(bucket(1), 0)
        XCTAssertEqual(bucket(0), 0)
        XCTAssertEqual(bucket(-15), 15)
        XCTAssertEqual(bucket(-16), 16)
        XCTAssertEqual(bucket(-128), 31)
        XCTAssertEqual(bucket(-100_000), 31)
    }
}
