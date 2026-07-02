import XCTest
@testable import DagDB
@testable import DagDBDaemonKit

/// Placeholder so the target compiles while the extraction settles.
/// Real handler/parser tests live alongside this file.
final class DagDBDaemonKitSmokeTests: XCTestCase {
    func testParserParsesStatus() {
        if case .status = DSLParser.parse("STATUS") { } else {
            XCTFail("STATUS should parse to .status")
        }
    }
}
