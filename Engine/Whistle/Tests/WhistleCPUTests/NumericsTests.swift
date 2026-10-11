import XCTest

@testable import WhistleCPU

final class NumericsTests: XCTestCase {
  func testActivationQuantizationUsesRowAbsmaxAndEvenTies() {
    let x: [Float] = [127, 0.5, 1.5, -0.5, -1.5]
    XCTAssertEqual(Math.a8(x), [127, 0, 2, 0, -2])
    XCTAssertEqual(Math.a8([0, 0]), [0, 0])
  }

  func testKronAppliesLeftTransposeAndRightMatrix() {
    // A.T @ [[1,2],[3,4]] @ B, not a row-major transposition shortcut.
    let a: [Float] = [1, 2, 3, 4]
    let b: [Float] = [2, 0, 1, 3]
    XCTAssertEqual(
      Math.kron([1, 2, 3, 4], a: a, aSize: 2, b: b, bSize: 2),
      [34, 42, 48, 60])
  }

  func testSinkhornProducesDoublyStochasticLaneMix() {
    let r = Math.sinkhorn([3, 1, 0, -1, 1, 2, -1, 0, 0, -2, 1, 3, -1, 0, 3, 2])
    // Twenty model iterations leave ~0.00018 row error; don't silently change the graph.
    let oracle: [Float] = [
      0.769639735, 0.174459258, 0.045620632, 0.010464230,
      0.167053237, 0.760579967, 0.026916785, 0.045620301,
      0.051608527, 0.011698441, 0.167021817, 0.769489403,
      0.011698501, 0.053262333, 0.760440766, 0.174426065,
    ]
    for (actual, expected) in zip(r, oracle) { XCTAssertEqual(actual, expected, accuracy: 1e-6) }
    for i in 0..<4 {
      XCTAssertEqual((0..<4).reduce(Float(0)) { $0 + r[i * 4 + $1] }, 1, accuracy: 2e-4)
      XCTAssertEqual((0..<4).reduce(Float(0)) { $0 + r[$1 * 4 + i] }, 1, accuracy: 1e-5)
    }
  }

  func testNormalizationIsRMSNotMeanSubtraction() {
    let r = Math.norm([3, 4], scale: [0, 1])
    XCTAssertEqual(r[0], 3 / sqrtf(12.5 + 1e-6), accuracy: 1e-6)
    XCTAssertEqual(r[1], 8 / sqrtf(12.5 + 1e-6), accuracy: 1e-6)
  }
}
