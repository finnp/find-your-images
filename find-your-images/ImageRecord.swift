import Foundation
import CoreData

/// A Core Data managed object representing a single indexed image.
///
/// Each `ImageRecord` holds a unique identifier, the file URL of the image
/// represented as a string, and the binary representation of the image's
/// feature print as produced by `VNGenerateImageFeaturePrintRequest`. The
/// feature print data is stored using `NSSecureCoding` and can be
/// reconstructed into a `VNFeaturePrintObservation` when needed.
@objc(ImageRecord)
public class ImageRecord: NSManagedObject {
    @NSManaged public var id: UUID
    @NSManaged public var url: String
    @NSManaged public var featurePrintData: Data
}