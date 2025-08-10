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

        entity.properties = [idAttribute, urlAttribute, featurePrintAttribute]
        model.entities = [entity]
        return model
    }
}