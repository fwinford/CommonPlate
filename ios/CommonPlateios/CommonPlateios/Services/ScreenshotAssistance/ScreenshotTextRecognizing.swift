//
//  ScreenshotTextRecognizing.swift
//  CommonPlateios
//
// W4-S3: on-device Vision OCR as a shared SERVICE that adapters may call. It is
// not part of the runtime's input contract: the shared input is the ordered
// pixel selection, and a workflow or provider adapter that wants recognized text
// asks for it here. Nothing here leaves the device, persists, or logs content.
import UIKit

protocol ScreenshotTextRecognizing {
    /// The recognized lines of `image`, joined with newlines in the order
    /// Vision reports them; empty when nothing is recognizable.
    func recognizeText(in image: ScreenshotPreparedImage) async -> String
}

/// Apple Vision OCR (`ScreenshotLocalTextRecognizer`) run against the
/// screenshot as it was selected, before normalization, for the best
/// recognition fidelity.
struct VisionScreenshotTextRecognizer: ScreenshotTextRecognizing {
    func recognizeText(in image: ScreenshotPreparedImage) async -> String {
        guard let uiImage = UIImage(data: image.sourceData) else { return "" }
        return await ScreenshotLocalTextRecognizer.recognizeText(in: uiImage)
    }
}
