import Foundation
import XCTest
@testable import CommonPlateios

/// W3-I3: participant verification's primary actions must be discoverable
/// without reading explanatory copy first. Without `ViewInspector` in this
/// target, this suite proves the accepted ordering by reading the view's own
/// tracked source — matching the source-inspection pattern already used
/// elsewhere in `CommonPlateiosTests` — rather than pinning incidental
/// SwiftUI formatting. Each assertion is scoped to the one section
/// declaration it is actually about, not the whole file, so an unrelated
/// identifier appearing earlier elsewhere in the source cannot produce a
/// false pass.
final class ParticipantVerificationHierarchyTests: XCTestCase {
    /// The accepted email-section hierarchy: the field and its action lead;
    /// the standing eligibility/purpose/replacement/revoked explanation comes
    /// after, not before.
    func testEmailSectionPutsTheFieldAndSendCodeBeforeSupportingExplanation() throws {
        let section = try declarationSource(
            startMarker: "private var emailSection: some View {",
            endMarker: "private func codeSection(address: String) -> some View {"
        )

        let fieldRange = try requiredRange(of: "participant-verification-email", in: section)
        let sendRange = try requiredRange(of: "participant-verification-send", in: section)
        let eligibilityRange = try requiredRange(of: "participant-verification-eligibility", in: section)

        XCTAssertLessThan(fieldRange.lowerBound, sendRange.lowerBound)
        XCTAssertLessThan(sendRange.lowerBound, eligibilityRange.lowerBound)
    }

    /// The accepted code-section hierarchy: the code field, Verify, and
    /// resend are the actionable controls and appear in that order. This
    /// makes no claim about the code-sent notice, which the production view
    /// deliberately places before the code field to say what to type next —
    /// that placement is unaffected by, and not part of, this slice's
    /// action-first hierarchy.
    func testCodeSectionOrdersCodeFieldVerifyThenResend() throws {
        let section = try declarationSource(
            startMarker: "private func codeSection(address: String) -> some View {",
            endMarker: "static func canSendCode(email: String, isRequesting: Bool) -> Bool {"
        )

        let codeFieldRange = try requiredRange(of: "participant-verification-code", in: section)
        let verifyRange = try requiredRange(of: "participant-verification-submit", in: section)
        let resendRange = try requiredRange(of: "participant-verification-resend", in: section)

        XCTAssertLessThan(codeFieldRange.lowerBound, verifyRange.lowerBound)
        XCTAssertLessThan(verifyRange.lowerBound, resendRange.lowerBound)
    }

    private func requiredRange(of identifier: String, in source: String) throws -> Range<String.Index> {
        try XCTUnwrap(
            source.range(of: identifier),
            "expected to find \(identifier)"
        )
    }

    /// Extracts one declaration's own source text — from `startMarker` up to
    /// (not including) `endMarker` — so an assertion about one section cannot
    /// be satisfied or defeated by unrelated content elsewhere in the file.
    private func declarationSource(startMarker: String, endMarker: String) throws -> String {
        let source = try String(
            contentsOf: repositoryFile(
                "ios/CommonPlateios/CommonPlateios/Views/ParticipantVerificationView.swift"
            ),
            encoding: .utf8
        )

        guard let startRange = source.range(of: startMarker) else {
            XCTFail("expected to find \(startMarker)")
            return ""
        }
        guard let endRange = source.range(of: endMarker, range: startRange.upperBound..<source.endIndex) else {
            XCTFail("expected to find \(endMarker) after \(startMarker)")
            return ""
        }

        return String(source[startRange.lowerBound..<endRange.lowerBound])
    }

    /// Walks up from this file to the repository root, so the source-text
    /// assertions above read the real tracked file rather than a copy.
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
