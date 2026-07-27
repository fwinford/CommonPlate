import Foundation
import XCTest
@testable import CommonPlateios

/// The requester form is paused until Day 3 connects `POST /api/request`.
/// Its guarantees are structural — where the notice sits relative to the
/// fields, and that the disabled control explains itself — so the ordering
/// assertions read the view source. The project has no view-inspection
/// dependency, and adding one for two assertions is not worth the weight.
final class RequestFormPauseTests: XCTestCase {
    private var source: String {
        get throws {
            let viewURL = URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("CommonPlateios/Views/RequestFoodView.swift")
            return try String(contentsOf: viewURL, encoding: .utf8)
        }
    }

    func testPauseNoticeUsesLockedProductCopy() {
        XCTAssertEqual(
            RequestFoodView.pauseNotice,
            "Posting a meal request is temporarily unavailable."
        )
    }

    func testPauseNoticeIsPresentedBeforeAnyFormField() throws {
        let source = try source
        let formStart = try XCTUnwrap(source.range(of: "Form {"))

        let notice = try XCTUnwrap(
            source.range(of: "Text(Self.pauseNotice)", range: formStart.upperBound..<source.endIndex),
            "The form must present the pause notice."
        )

        // The first thing the student can type into or choose from.
        let firstField = try XCTUnwrap(
            [#"Picker("NYU dining spot""#, #"TextField("What do you want?""#]
                .compactMap { source.range(of: $0) }
                .min(by: { $0.lowerBound < $1.lowerBound }),
            "The form must still collect request details."
        )

        XCTAssertLessThan(
            notice.lowerBound,
            firstField.lowerBound,
            "The pause notice must appear before the first form field."
        )
    }

    func testDisabledSubmitControlExplainsItself() throws {
        let source = try source
        let submitButton = try XCTUnwrap(source.range(of: #"Button("Submit Request")"#))
        let remainder = source[submitButton.upperBound...]

        XCTAssertTrue(
            remainder.contains(".disabled(true)"),
            "Submission must remain disabled until Day 3."
        )
        XCTAssertTrue(
            remainder.contains(".accessibilityHint(Self.pauseNotice)"),
            "A dimmed control must carry its reason for assistive technology."
        )
    }

    /// The Week 1 prototype reported success for a request that was never
    /// persisted. Nothing may reintroduce that while creation is paused.
    func testNoSimulatedSubmissionSuccessRemains() throws {
        let source = try source

        XCTAssertTrue(
            source.contains(#"Button("Submit Request") {}"#),
            "The submit action must stay empty, not merely disabled."
        )
        XCTAssertFalse(source.contains("dismiss()"))
        XCTAssertFalse(source.contains("LocalSimulatedRequest"))
        XCTAssertFalse(source.lowercased().contains("showsuccess"))
    }
}
