import Foundation

/// Persists and manages the list of user-selected root folders to index.
enum IndexedFoldersStore {
    private static let key = "IndexedRootFolders.v1"

    /// Loads the saved root folders.
    static func load() -> [URL] {
        let defaults = UserDefaults.standard
        guard let paths = defaults.array(forKey: key) as? [String] else { return [] }
        return paths.compactMap { URL(fileURLWithPath: $0) }
    }

    /// Saves the provided list of root folders, replacing the existing list.
    private static func save(_ urls: [URL]) {
        let defaults = UserDefaults.standard
        let paths = urls.map { $0.standardizedFileURL.path }
        defaults.set(paths, forKey: key)
    }

    /// Adds a root folder to the saved list. No-op if it already exists.
    static func add(_ url: URL) {
        let path = url.standardizedFileURL.path
        var existing = Set(load().map { $0.standardizedFileURL.path })
        guard existing.insert(path).inserted else { return }
        let urls = existing.map { URL(fileURLWithPath: $0) }.sorted { $0.path.localizedCaseInsensitiveCompare($1.path) == .orderedAscending }
        save(urls)
    }

    /// Removes a root folder from the saved list. No-op if absent.
    static func remove(_ url: URL) {
        let path = url.standardizedFileURL.path
        var remaining = load().map { $0.standardizedFileURL.path }.filter { $0 != path }
        remaining.sort { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        let urls = remaining.map { URL(fileURLWithPath: $0) }
        save(urls)
    }
}

