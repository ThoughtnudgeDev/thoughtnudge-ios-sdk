import XCTest
@testable import ThoughtNudgeSDK

final class ThoughtNudgeSDKTests: XCTestCase {
    func testInitialization() {
        // Basic test to verify the SDK can be instantiated
        let sdk = ThoughtNudgeSDK.shared
        XCTAssertNotNil(sdk)
    }
}
