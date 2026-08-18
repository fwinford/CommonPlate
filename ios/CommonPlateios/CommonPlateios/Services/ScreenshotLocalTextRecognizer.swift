//
//  ScreenshotLocalTextRecognizer.swift
//  CommonPlateios
//
// W4-S1 independent evidence source. Apple Vision — a different, local,
// non-LLM OCR engine — is run on the selected screenshot before it is ever
// sent to OpenAI, and its output is the only text `screenshotProposalRoute.ts`
// trusts for eligibility and meal-swipe corroboration. OpenAI's own output
// is never used to validate itself: asking the same model that produced a
// claim to also produce the evidence that claim is checked against is not
// independent corroboration.
import UIKit
import Vision

enum ScreenshotLocalTextRecognizer {
    /// Recognizes all visible text in `image` using on-device Vision OCR.
    /// Returns the recognized lines joined with newlines, in the order
    /// Vision reports them; an image with no recognizable text returns an
    /// empty string, which the backend's own legibility threshold simply
    /// rejects as ineligible rather than this method treating it specially.
    static func recognizeText(in image: UIImage) async -> String {
        guard let cgImage = image.cgImage else { return "" }

        return await withCheckedContinuation { continuation in
            let request = VNRecognizeTextRequest { request, _ in
                let observations = request.results as? [VNRecognizedTextObservation] ?? []
                let lines = observations.compactMap { $0.topCandidates(1).first?.string }
                continuation.resume(returning: lines.joined(separator: "\n"))
            }
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = false

            let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
            do {
                try handler.perform([request])
            } catch {
                continuation.resume(returning: "")
            }
        }
    }
}
