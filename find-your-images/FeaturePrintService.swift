import Foundation
import Vision
import AppKit

/// A utility responsible for generating image feature prints and computing
/// distances between them. Feature prints encapsulate the salient visual
/// content of an image in a compact form using Apple’s Vision framework.
enum FeaturePrintService {
    /// Generates a feature print observation from an image at the provided URL.
    ///
    /// - Parameter url: A file URL pointing to the image to analyse.
    /// - Returns: A `VNFeaturePrintObservation` containing the image’s feature
    ///   print, or `nil` if the request failed.
    static func generateFeaturePrint(for url: URL) throws -> VNFeaturePrintObservation? {
        let request = VNGenerateImageFeaturePrintRequest()
        let handler = try VNImageRequestHandler(url: url, options: [:])
        try handler.perform([request])
        return request.results?.first as? VNFeaturePrintObservation
    }

    /// Calculates the distance between two feature prints.
    ///
    /// The Vision framework defines distance as a floating‑point value where
    /// lower values indicate more similar images. This method throws an
    /// exception if the two feature prints are incompatible (for example,
    /// generated with different request revisions).
    ///
    /// - Parameters:
    ///   - a: The first feature print.
    ///   - b: The second feature print.
    /// - Returns: The computed distance as a `Float`.
    static func distance(between a: VNFeaturePrintObservation, and b: VNFeaturePrintObservation) throws -> Float {
        var distance: Float = 0
        try a.computeDistance(&distance, to: b)
        return distance
    }

    /// Loads an `NSImage` from the given file URL.
    ///
    /// - Parameter url: The URL of the image file to load.
    /// - Returns: An `NSImage` object if loading succeeds, or `nil` on failure.
    static func loadImage(from url: URL) -> NSImage? {
        return NSImage(contentsOf: url)
    }
}