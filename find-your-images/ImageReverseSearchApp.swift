import SwiftUI

/// The main entry point for the reverse image search app.
@main
struct ImageReverseSearchApp: App {
    /// A shared persistence controller for managing Core Data interactions.
    ///
    /// This controller provides a single `NSPersistentContainer` instance that
    /// is shared across the app. When creating a macOS app with Core Data
    /// outside of an Xcode template, you must supply the managed object model
    /// yourself. See `PersistenceController` for more details.
    let persistenceController = PersistenceController.shared

    var body: some Scene {
        WindowGroup {
            ContentView()
                // Inject the managed object context into the environment so
                // SwiftUI views can access it via the `@Environment` property wrapper.
                .environment(\.managedObjectContext, persistenceController.container.viewContext)
        }
    }
}