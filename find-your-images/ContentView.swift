import SwiftUI
import CoreData
import Vision
import UniformTypeIdentifiers
import AppKit

/// The main user interface for the reverse image search application.
///
/// This view allows the user to pick a folder of images to index using
/// Apple's Vision framework, persist the generated feature prints to Core
/// Data, and then drop arbitrary images onto a designated area to find
/// their closest match from the indexed set.
struct ContentView: View {
    // Access to the managed object context injected at the app entry point.
    @Environment(\.managedObjectContext) private var context

    // Fetch all `ImageRecord` objects sorted by their URL. The view updates
    // automatically when records change.
    @FetchRequest(sortDescriptors: [SortDescriptor(\.url, order: .forward)])
    private var records: FetchedResults<ImageRecord>

    /// Indicates whether the app is currently indexing images.
    @State private var isIndexing: Bool = false

    /// A status message to display progress or results to the user.
    @State private var statusMessage: String = ""

    /// Total number of images to index in the selected folder.
    @State private var totalToIndex: Int = 0

    /// Number of images processed so far during indexing.
    @State private var processedCount: Int = 0

    /// The date when the current indexing run started, used to compute ETA.
    @State private var indexingStartDate: Date? = nil

    /// The folder currently being indexed.
    @State private var currentIndexingFolder: URL? = nil

    /// The filename currently being processed.
    @State private var currentFileName: String = ""

    /// Controls delete confirmation for an indexed folder.
    @State private var showDeleteAlert: Bool = false
    @State private var folderPendingDeletion: URL? = nil

    /// Represents an indexed folder with a count of contained records.
    struct IndexedFolder: Identifiable, Hashable {
        let url: URL
        let count: Int
        var id: String { url.path }
    }

    /// Segmented control mode for the main view.
    private enum Mode: Hashable { case search, importing }
    @State private var selectedMode: Mode = .search

    /// Cached counts for indexed folders to avoid recomputing on every change.
    @State private var folderCounts: [String: Int] = [:]

    /// Aggregated counts for user-selected root folders only, sourced from cache.
    private var indexedFolders: [IndexedFolder] {
        let roots = IndexedFoldersStore.load().map { $0.standardizedFileURL }
        guard !roots.isEmpty else { return [] }
        let groups = roots.map { root in IndexedFolder(url: root, count: folderCounts[root.path] ?? 0) }
        return groups.sorted { $0.url.path.localizedCaseInsensitiveCompare($1.url.path) == .orderedAscending }
    }

    /// The image dropped by the user for searching. Displayed in the UI.
    @State private var queryImage: NSImage? = nil

    /// The URL of the best matching image, if one was found.
    @State private var matchURL: URL? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Picker("", selection: $selectedMode) {
                Text("Search").tag(Mode.search)
                Text("Import").tag(Mode.importing)
            }
            .pickerStyle(.segmented)

            switch selectedMode {
            case .search:
                VStack(alignment: .leading, spacing: 12) {
                    Text("Drop an image below to search for a match:")
                        .font(.headline)
                    dropTarget
                    if !statusMessage.isEmpty {
                        Text(statusMessage)
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }
                    if let queryImage = queryImage {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Query Image:")
                                .font(.subheadline)
                            Image(nsImage: queryImage)
                                .resizable()
                                .scaledToFit()
                                .frame(maxHeight: 200)
                                .border(Color.gray.opacity(0.3))
                        }
                    }
                    if let matchURL = matchURL {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Best Match:")
                                .font(.subheadline)
                            if let matchedImage = FeaturePrintService.loadImage(from: matchURL) {
                                Image(nsImage: matchedImage)
                                    .resizable()
                                    .scaledToFit()
                                    .frame(maxHeight: 200)
                                    .border(Color.green.opacity(0.4))
                            }
                            Text(matchURL.lastPathComponent)
                                .foregroundColor(.secondary)
                        }
                    }
                }

            case .importing:
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 12) {
                        Button(action: selectAndIndexFolder) {
                            Text("Select Folder or Drive…")
                        }
                        .disabled(isIndexing)
                        if isIndexing {
                            ProgressView(value: Double(processedCount), total: Double(max(totalToIndex, 1)))
                                .frame(width: 220)
                            Text(etaDisplay())
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                    if !statusMessage.isEmpty {
                        Text(statusMessage)
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }
                    if isIndexing {
                        VStack(alignment: .leading, spacing: 4) {
                            if let folder = currentIndexingFolder {
                                Text("Indexing: \(folder.path)")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                            Text("\(processedCount)/\(max(totalToIndex, 1)) • \(currentFileName)")
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }
                    Divider()
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Indexed Folders")
                            .font(.headline)
                        if indexedFolders.isEmpty {
                            Text("No indexed folders yet.")
                                .foregroundColor(.secondary)
                        } else {
                            ScrollView {
                                LazyVStack(alignment: .leading, spacing: 8) {
                                    ForEach(indexedFolders) { folder in
                                        HStack(alignment: .firstTextBaseline) {
                                            HStack(spacing: 8) {
                                                Image(systemName: systemImageForFolder(folder.url))
                                                    .foregroundColor(.secondary)
                                                VStack(alignment: .leading, spacing: 2) {
                                                    Text(folder.url.lastPathComponent)
                                                        .font(.subheadline)
                                                    Text(folder.url.path)
                                                        .font(.caption)
                                                        .foregroundColor(.secondary)
                                                }
                                            }
                                            Spacer()
                                            Text("\(folder.count)")
                                                .font(.caption)
                                                .padding(.trailing, 8)
                                            Button(role: .destructive) {
                                                folderPendingDeletion = folder.url
                                                showDeleteAlert = true
                                            } label: {
                                                Text("Delete")
                                            }
                                        }
                                        .padding(8)
                                        .background(Color.gray.opacity(0.08))
                                        .cornerRadius(6)
                                    }
                                }
                            }
                            .frame(maxHeight: 200)
                        }
                    }
                }
            }

            Spacer()
        }
        .padding()
        .frame(minWidth: 500, minHeight: 600)
        .alert("Delete Indexed Folder?", isPresented: $showDeleteAlert, presenting: folderPendingDeletion) { url in
            Button("Delete", role: .destructive) {
                Task {
                    await deleteIndexedFolder(url)
                    IndexedFoldersStore.remove(url)
                }
            }
            Button("Cancel", role: .cancel) {
                folderPendingDeletion = nil
            }
        } message: { url in
            Text("This will remove all indexed images under \(url.path). This cannot be undone.")
        }
        .onAppear {
            recomputeFolderCountsFromRecords()
        }
    }

    /// A view representing the drop area. Accepts file URLs of images and
    /// triggers a search for the closest match upon drop.
    private var dropTarget: some View {
        RoundedRectangle(cornerRadius: 8)
            .strokeBorder(style: StrokeStyle(lineWidth: 2, dash: [6]))
            .foregroundColor(Color.accentColor)
            .frame(height: 160)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color(NSColor.windowBackgroundColor).opacity(0.5))
            )
            .overlay(
                Text("Drag & Drop Image Here")
                    .foregroundColor(.secondary)
            )
            .onDrop(of: [UTType.fileURL.identifier], isTargeted: nil) { providers in
                guard let provider = providers.first else { return false }
                _ = provider.loadObject(ofClass: URL.self) { url, error in
                    if let url = url {
                        searchForMatch(with: url)
                    }
                }
                return true
            }
    }

    /// Opens an `NSOpenPanel` allowing the user to select a directory to index.
    private func selectAndIndexFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Index"
        panel.directoryURL = URL(fileURLWithPath: "/Volumes/")
        if panel.runModal() == .OK, let folderURL = panel.url {
            Task {
                IndexedFoldersStore.add(folderURL)
                await indexImages(in: folderURL)
            }
        }
    }

    /// Iterates through image files in the given directory and stores their
    /// feature prints in Core Data. Skips files that have already been
    /// indexed.
    ///
    /// - Parameter folderURL: The directory to index.
    private func indexImages(in folderURL: URL) async {
        await MainActor.run {
            isIndexing = true
            statusMessage = "Scanning folder…"
            processedCount = 0
            totalToIndex = 0
            indexingStartDate = nil
            currentIndexingFolder = folderURL
            currentFileName = ""
        }

        // Snapshot existing URLs on the main actor to avoid context hops later
        let existingURLs: Set<String> = await MainActor.run { Set(records.map { $0.url }) }

        // Build candidate list
        let allowedExtensions: Set<String> = ["jpg", "jpeg", "png", "heic", "tiff", "bmp"]
        var candidates: [URL] = []
        let fileManager = FileManager.default
        guard let enumerator = fileManager.enumerator(
            at: folderURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            await MainActor.run {
                statusMessage = "Failed to enumerate folder."
                isIndexing = false
                currentIndexingFolder = nil
            }
            return
        }

        for case let fileURL as URL in enumerator {
            let ext = fileURL.pathExtension.lowercased()
            if allowedExtensions.contains(ext) && !existingURLs.contains(fileURL.path) {
                candidates.append(fileURL)
            }
        }

        await MainActor.run {
            totalToIndex = candidates.count
            indexingStartDate = Date()
            statusMessage = candidates.isEmpty ? "No new images to index." : "Indexing images…"
        }

        if candidates.isEmpty {
            await MainActor.run {
                isIndexing = false
                currentIndexingFolder = nil
            }
            return
        }

        let backgroundContext = PersistenceController.shared.container.newBackgroundContext()
        backgroundContext.mergePolicy = NSMergeByPropertyObjectTrumpMergePolicy
        backgroundContext.undoManager = nil

        let batchSize = 50
        let progressStride = max(1, totalToIndex / 100)
        var successfullyIndexed = 0
        var insertedSinceLastSave = 0
        var processedSinceLastUpdate = 0
        for fileURL in candidates {
            var archivedData: Data? = nil
            autoreleasepool {
                do {
                    if let observation = try FeaturePrintService.generateFeaturePrint(for: fileURL) {
                        archivedData = try NSKeyedArchiver.archivedData(withRootObject: observation, requiringSecureCoding: true)
                    }
                } catch {
                    // Non‑fatal; skip problematic images
                    print("Error indexing \(fileURL.lastPathComponent): \(error)")
                }
            }
            if let data = archivedData {
                await backgroundContext.perform {
                    let record = ImageRecord(context: backgroundContext)
                    record.id = UUID()
                    record.url = fileURL.path
                    record.featurePrintData = data
                }
                successfullyIndexed += 1
                insertedSinceLastSave += 1
            }
            if insertedSinceLastSave >= batchSize {
                await backgroundContext.perform {
                    if backgroundContext.hasChanges {
                        do { try backgroundContext.save() } catch { }
                    }
                }
                insertedSinceLastSave = 0
            }
            processedSinceLastUpdate += 1
            if processedSinceLastUpdate >= progressStride {
                let filename = fileURL.lastPathComponent
                await MainActor.run {
                    processedCount += processedSinceLastUpdate
                    currentFileName = filename
                }
                processedSinceLastUpdate = 0
            }
        }
        // Save any remaining inserts
        await backgroundContext.perform {
            if backgroundContext.hasChanges {
                do { try backgroundContext.save() } catch { }
            }
        }

        // Final progress update and recompute folder counts
        await MainActor.run {
            processedCount = totalToIndex
            currentFileName = ""
        }
        await MainActor.run {
            statusMessage = successfullyIndexed == 0 ? "No new images indexed." : "Indexed \(successfullyIndexed) of \(totalToIndex) images."
            isIndexing = false
            currentIndexingFolder = nil
            recomputeFolderCountsFromRecords()
        }
    }

    /// Returns a human‑readable ETA string for the current indexing session.
    private func etaDisplay() -> String {
        guard isIndexing, let start = indexingStartDate, totalToIndex > 0, processedCount > 0 else {
            return "ETA —"
        }
        let elapsed = Date().timeIntervalSince(start)
        let perItem = elapsed / Double(processedCount)
        let remainingItems = max(totalToIndex - processedCount, 0)
        let remainingSeconds = perItem * Double(remainingItems)
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = remainingSeconds >= 3600 ? [.hour, .minute, .second] : [.minute, .second]
        formatter.unitsStyle = .abbreviated
        formatter.zeroFormattingBehavior = .pad
        let formatted = formatter.string(from: remainingSeconds) ?? "—"
        return "ETA \(formatted)"
    }

    /// Deletes all indexed records that reside under the specified folder (including subfolders).
    private func deleteIndexedFolder(_ folderURL: URL) async {
        let folderPath = folderURL.standardizedFileURL.path
        await MainActor.run {
            statusMessage = "Deleting indexed folder…"
        }

        let backgroundContext = PersistenceController.shared.container.newBackgroundContext()
        backgroundContext.mergePolicy = NSMergeByPropertyObjectTrumpMergePolicy
        await backgroundContext.perform {
            let fetch = NSFetchRequest<ImageRecord>(entityName: "ImageRecord")
            // Ensure we only match paths strictly under the folder by appending a trailing slash
            let prefix = folderPath.hasSuffix("/") ? folderPath : folderPath + "/"
            fetch.predicate = NSPredicate(format: "url BEGINSWITH %@", prefix)
            do {
                let items = try backgroundContext.fetch(fetch)
                for item in items {
                    backgroundContext.delete(item)
                }
                if backgroundContext.hasChanges {
                    try backgroundContext.save()
                }
            } catch {
                print("Error deleting records in folder: \(error)")
            }
        }

        await MainActor.run {
            statusMessage = "Deleted indexed folder: \(folderURL.lastPathComponent)"
            folderPendingDeletion = nil
            recomputeFolderCountsFromRecords()
        }
    }

    /// Recomputes the displayed counts for saved root folders using current records.
    private func recomputeFolderCountsFromRecords() {
        let roots = IndexedFoldersStore.load().map { $0.standardizedFileURL }
        var counts: [String: Int] = [:]
        if roots.isEmpty {
            folderCounts = [:]
            return
        }
        let normalizedRoots: [(pathWithSlash: String, root: URL)] = roots.map { root in
            let p = root.path
            return ((p.hasSuffix("/") ? p : p + "/"), root)
        }
        for record in records {
            let imagePath = URL(fileURLWithPath: record.url).standardizedFileURL.path
            for (pathWithSlash, root) in normalizedRoots {
                if imagePath == root.path || imagePath.hasPrefix(pathWithSlash) {
                    counts[root.path, default: 0] += 1
                    break
                }
            }
        }
        folderCounts = counts
    }

    /// Returns a system image name for representing the given folder URL.
    /// If it appears to be on an external volume (path under /Volumes), a drive icon is used.
    private func systemImageForFolder(_ url: URL) -> String {
        let path = url.standardizedFileURL.path
        if path.hasPrefix("/Volumes/") {
            return "externaldrive"
        }
        return "folder"
    }

    /// Computes the best matching image for the given query URL.
    ///
    /// Reads the stored feature prints from Core Data, calculates the distance
    /// between the query image’s feature print and each stored print using
    /// `VNFeaturePrintObservation.computeDistance`, and records the smallest
    /// distance. Updates the UI state when finished.
    ///
    /// - Parameter queryURL: The URL of the image dropped onto the UI.
    private func searchForMatch(with queryURL: URL) {
        queryImage = FeaturePrintService.loadImage(from: queryURL)
        matchURL = nil
        statusMessage = "Searching…"
        Task {
            do {
                guard let queryObservation = try FeaturePrintService.generateFeaturePrint(for: queryURL) else {
                    await MainActor.run { statusMessage = "Unable to generate feature print for query." }
                    return
                }
                var bestDistance: Float = Float.greatestFiniteMagnitude
                var bestRecord: ImageRecord? = nil
                for record in records {
                    guard let observationData = try? NSKeyedUnarchiver.unarchivedObject(ofClass: VNFeaturePrintObservation.self, from: record.featurePrintData) else {
                        continue
                    }
                    do {
                        let distance = try FeaturePrintService.distance(between: queryObservation, and: observationData)
                        if distance < bestDistance {
                            bestDistance = distance
                            bestRecord = record
                        }
                    } catch {
                        // Ignore mismatched feature print revisions
                        continue
                    }
                }
                if let match = bestRecord {
                    let matchFileURL = URL(fileURLWithPath: match.url)
                    await MainActor.run {
                        matchURL = matchFileURL
                        statusMessage = String(format: "Best match found (distance = %.4f)", bestDistance)
                    }
                } else {
                    await MainActor.run { statusMessage = "No match found." }
                }
            } catch {
                await MainActor.run { statusMessage = "Error during search: \(error.localizedDescription)" }
            }
        }
    }
}

// Preview provider for SwiftUI previews. Previews will use an in‑memory store.
struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        let controller = PersistenceController(inMemory: true)
        return ContentView()
            .environment(\.managedObjectContext, controller.container.viewContext)
    }
}