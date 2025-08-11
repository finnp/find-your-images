import Foundation
import CoreData

/// A helper class responsible for configuring and providing a Core Data stack.
///
/// When building a SwiftUI app with Core Data outside of the default Xcode
/// templates, you must provide a fully initialised `NSPersistentContainer`.
/// This struct encapsulates the boilerplate needed to create an in‑memory
/// or on‑disk persistent store and defines the managed object model in code.
struct PersistenceController {
    /// A singleton instance used throughout the application.
    static let shared = PersistenceController()

    /// The underlying Core Data container.
    let container: NSPersistentContainer

    /// Creates a new persistence controller.
    ///
    /// - Parameter inMemory: When `true` the persistent store is kept
    ///   entirely in memory. This is useful for previews or unit tests. When
    ///   `false` (the default) a SQLite store is created on disk in the app
    ///   container.
    init(inMemory: Bool = false) {
        // Define the managed object model manually. This avoids the need
        // for an `.xcdatamodeld` file. The model consists of a single
        // entity called `ImageRecord` with three properties: `id`, `url`
        // and `featurePrintData`.
        let model = Self.makeModel()
        container = NSPersistentContainer(name: "ImageReverseSearch", managedObjectModel: model)

        if inMemory {
            // Direct writes to `/dev/null` to avoid creating any files on disk.
            container.persistentStoreDescriptions.first?.url = URL(fileURLWithPath: "/dev/null")
        }

        // Enable lightweight migration so adding optional attributes like `dhash`
        // does not break existing stores.
        if let desc = container.persistentStoreDescriptions.first {
            desc.setOption(true as NSNumber, forKey: NSMigratePersistentStoresAutomaticallyOption)
            desc.setOption(true as NSNumber, forKey: NSInferMappingModelAutomaticallyOption)
        }

        // Load the persistent stores synchronously.
        container.loadPersistentStores { description, error in
            if let error = error as NSError? {
                fatalError("Unresolved error \(error), \(error.userInfo)")
            }
        }

        // Merge policy ensures that in case of conflict the in‑memory version
        // takes precedence. Without setting this, saving may throw.
        container.viewContext.mergePolicy = NSMergeByPropertyObjectTrumpMergePolicy
        // Ensure UI updates when background contexts save.
        container.viewContext.automaticallyMergesChangesFromParent = true
    }

    /// Defines the managed object model used by the persistence controller.
    ///
    /// The model contains a single entity called `ImageRecord` with the
    /// following attributes:
    ///
    /// - `id`: A UUID uniquely identifying each record.
    /// - `url`: A string representation of the image URL.
    /// - `featurePrintData`: A binary blob storing an encoded
    ///   `VNFeaturePrintObservation`. Since `VNFeaturePrintObservation` conforms
    ///   to `NSSecureCoding`, it can be archived and unarchived safely.
    ///
    /// - Returns: A fully constructed `NSManagedObjectModel` ready for use by
    ///   an `NSPersistentContainer`.
    private static func makeModel() -> NSManagedObjectModel {
        let model = NSManagedObjectModel()
        let entity = NSEntityDescription()
        entity.name = "ImageRecord"
        entity.managedObjectClassName = NSStringFromClass(ImageRecord.self)

        // Unique identifier
        let idAttribute = NSAttributeDescription()
        idAttribute.name = "id"
        idAttribute.attributeType = .UUIDAttributeType
        idAttribute.isOptional = false

        // URL stored as string. Using URIAttributeType can lead to issues
        // with relative paths when persisting; storing as string keeps things simple.
        let urlAttribute = NSAttributeDescription()
        urlAttribute.name = "url"
        urlAttribute.attributeType = .stringAttributeType
        urlAttribute.isOptional = false

        // Encoded feature print observation
        let featurePrintAttribute = NSAttributeDescription()
        featurePrintAttribute.name = "featurePrintData"
        featurePrintAttribute.attributeType = .binaryDataAttributeType
        featurePrintAttribute.allowsExternalBinaryDataStorage = true
        featurePrintAttribute.isOptional = false

        // Image width in pixels
        let widthAttribute = NSAttributeDescription()
        widthAttribute.name = "width"
        widthAttribute.attributeType = .integer64AttributeType
        widthAttribute.isOptional = false
        widthAttribute.defaultValue = 0

        // Image height in pixels
        let heightAttribute = NSAttributeDescription()
        heightAttribute.name = "height"
        heightAttribute.attributeType = .integer64AttributeType
        heightAttribute.isOptional = false
        heightAttribute.defaultValue = 0

        // File size in bytes
        let sizeAttribute = NSAttributeDescription()
        sizeAttribute.name = "fileSize"
        sizeAttribute.attributeType = .integer64AttributeType
        sizeAttribute.isOptional = false
        sizeAttribute.defaultValue = 0

        // 64-bit perceptual dHash for visual similarity via Hamming distance
        let dhashAttribute = NSAttributeDescription()
        dhashAttribute.name = "dhash"
        dhashAttribute.attributeType = .integer64AttributeType
        dhashAttribute.isOptional = true
        dhashAttribute.defaultValue = 0

        entity.properties = [idAttribute, urlAttribute, featurePrintAttribute, widthAttribute, heightAttribute, sizeAttribute, dhashAttribute]
        model.entities = [entity]
        return model
    }
}