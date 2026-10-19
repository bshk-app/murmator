import Foundation
import XCTest
@testable import MurmurCloud

final class DictatorGatewayEndpointTests: XCTestCase {
    func testKnownOperationURLsBecomeTheGatewayBase() {
        let root = "https://gateway.example"
        for suffix in ["", "/", "/v1", "/v1/", "/v1/audio/transcriptions", "/v1/audio/transcriptions/", "/v1/stream", "/v1/translate"] {
            XCTAssertEqual(DictatorGatewayEndpoint.baseURL(URL(string: root + suffix)!).absoluteString, root, suffix)
        }
    }

    func testReverseProxyPrefixIsPreserved() {
        let root = "https://gateway.example/proxy/dictator"
        for suffix in ["", "/v1", "/v1/audio/transcriptions", "/v1/stream", "/v1/translate"] {
            XCTAssertEqual(DictatorGatewayEndpoint.baseURL(URL(string: root + suffix)!).absoluteString, root, suffix)
        }
    }

    func testUnrecognizedPathsAndSecurityFieldsArePreserved() {
        for address in ["https://gateway.example/custom/path", "http://gateway.example", "https://user:password@gateway.example", "https://gateway.example?token=value", "https://gateway.example#fragment"] {
            let url = URL(string: address)!
            XCTAssertEqual(DictatorGatewayEndpoint.baseURL(url), url, address)
        }
    }
}
