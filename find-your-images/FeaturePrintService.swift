import Foundation
import Vision
import AppKit
import CoreGraphics

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
    /// Tries several strategies for robustness, in order of cost.
    static func loadImage(from url: URL) -> NSImage? {
        let fileURL = url.isFileURL ? url : URL(fileURLWithPath: url.path)
        if let img = NSImage(contentsOf: fileURL) { return img }
        if let img = NSImage(contentsOfFile: fileURL.path) { return img }
        let byRef = NSImage(byReferencing: fileURL)
        if byRef.isValid, byRef.size != .zero { return byRef }
        if let data = try? Data(contentsOf: fileURL), let img = NSImage(data: data) { return img }
        return nil
    }

    // Keeping thumbnail loader available (unused currently) in case we need
    // faster large-image previews later.
    static func loadThumbnail(from url: URL, maxPixelSize: Int) -> NSImage? {
        let fileURL = url.isFileURL ? url : URL(fileURLWithPath: url.path)
        guard let src = CGImageSourceCreateWithURL(fileURL as CFURL, nil) else { return loadImage(from: fileURL) }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageIfAbsent: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize
        ]
        guard let cgThumb = CGImageSourceCreateThumbnailAtIndex(src, 0, options as CFDictionary) else {
            return loadImage(from: fileURL)
        }
        let size = NSSize(width: cgThumb.width, height: cgThumb.height)
        let img = NSImage(size: size)
        img.addRepresentation(NSBitmapImageRep(cgImage: cgThumb))
        return img
    }

    /// Computes a 64-bit perceptual difference hash (dHash) for the image at the given URL.
    ///
    /// The algorithm downsamples the image to a 9x8 grayscale image and compares adjacent
    /// pixels horizontally, setting one bit per comparison. The resulting 64-bit value is
    /// robust to minor changes and correlates with visual similarity under Hamming distance.
    /// - Parameter url: The image file URL.
    /// - Returns: A 64-bit hash, or `nil` if the image cannot be decoded.
    static func computeDHash(for url: URL) -> UInt64? {
        let fileURL = url.isFileURL ? url : URL(fileURLWithPath: url.path)
        guard let src = CGImageSourceCreateWithURL(fileURL as CFURL, nil),
              let cgImage = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
            return nil
        }

        let targetWidth = 9
        let targetHeight = 8
        let colorSpace = CGColorSpaceCreateDeviceGray()
        let bitmapInfo = CGImageAlphaInfo.none.rawValue
        guard let ctx = CGContext(
            data: nil,
            width: targetWidth,
            height: targetHeight,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        ) else { return nil }
        ctx.interpolationQuality = .none
        ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: targetWidth, height: targetHeight))

        guard let dataPtr = ctx.data else { return nil }
        let bytesPerRow = ctx.bytesPerRow
        let buffer = dataPtr.bindMemory(to: UInt8.self, capacity: bytesPerRow * targetHeight)

        var hash: UInt64 = 0
        var bitIndex: Int = 0
        for y in 0..<targetHeight {
            let rowOffset = y * bytesPerRow
            for x in 0..<(targetWidth - 1) { // compare horizontally (x vs x+1)
                let left = buffer[rowOffset + x]
                let right = buffer[rowOffset + x + 1]
                if left > right {
                    hash |= (1 << UInt64(bitIndex))
                }
                bitIndex += 1
            }
        }
        return hash
    }

    /// Computes the Hamming distance between two 64-bit hashes.
    static func hammingDistance(_ a: UInt64, _ b: UInt64) -> Int {
        return (a ^ b).nonzeroBitCount
    }
}