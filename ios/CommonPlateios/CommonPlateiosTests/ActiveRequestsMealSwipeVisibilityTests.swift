//
//  ActiveRequestsMealSwipeVisibilityTests.swift
//  CommonPlateiosTests
//
//  W3-C1: the Active Requests list/card must show a request's existing
//  Request-owned `mealSwipes` value before a helper opens Request Detail.
//  This pins that `RequestRowView` presents it, independent of the
//  already-covered `RequestDetailView` pre-Reserve presentation.
//

import XCTest
@testable import CommonPlateios

final class ActiveRequestsMealSwipeVisibilityTests: XCTestCase {

    func testTheActiveRequestsRowPresentsTheRequestOwnedMealSwipeQuantity() throws {
        let source = try String(
            contentsOf: repositoryFile(
                "ios/CommonPlateios/CommonPlateios/Views/ActiveRequestsView.swift"
            ),
            encoding: .utf8
        )

        guard let rowRange = source.range(of: "struct RequestRowView") else {
            XCTFail("RequestRowView moved or was renamed")
            return
        }
        let rowBody = source[rowRange.lowerBound...]

        XCTAssertTrue(
            rowBody.contains("Meal swipes: \\(request.mealSwipes)"),
            "RequestRowView no longer shows the request's meal-swipe quantity"
        )
    }

    private func repositoryFile(_ relativePath: String) throws -> URL {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // CommonPlateiosTests
            .deletingLastPathComponent() // CommonPlateios
            .deletingLastPathComponent() // ios
            .deletingLastPathComponent() // repository root
        let url = root.appendingPathComponent(relativePath)
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: url.path),
            "expected \(relativePath) at \(url.path)"
        )
        return url
    }
}
