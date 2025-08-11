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

    /// Top search results for the last query.
    struct SearchResult: Identifiable, Hashable {
        let url: URL
        let width: Int64
        let height: Int64
        let fileSize: Int64
        let distance: Float
        var id: String { url.path }
    }
    @State private var matchResults: [SearchResult] = []
    @State private var resultsScrollId: UUID = UUID()
    @State private var databaseSizeBytes: Int64 = 0

    // Simple toast state
    @State private var toastMessage: String? = nil
    @State private var isToastVisible: Bool = false

    /// Lightweight on-demand thumbnail loader to ensure previews appear per row.
    struct ThumbnailView: View {
        let url: URL
        let size: CGFloat
        @State private var image: NSImage? = nil
        @State private var didAttempt: Bool = false

        var body: some View {
            ZStack {
                if let image = image {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFill()
                } else if didAttempt {
                    Rectangle()
                        .fill(Color.gray.opacity(0.15))
                        .overlay(Image(systemName: "photo").foregroundColor(.secondary))
                } else {
                    Rectangle()
                        .fill(Color.gray.opacity(0.2))
                        .overlay(ProgressView().scaleEffect(0.6))
                }
            }
            .frame(width: size, height: size)
            .clipped()
            .cornerRadius(4)
            .task(id: url) {
                guard image == nil else { return }
                didAttempt = true
                image = FeaturePrintService.loadThumbnail(from: url, maxPixelSize: Int(size * 3))
                    ?? FeaturePrintService.loadImage(from: url)
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Picker("", selection: $selectedMode) {
                Text("Search").tag(Mode.search)
                Text("Import").tag(Mode.importing)
            }
            .pickerStyle(.segmented)
            .padding(.bottom, 4)

            switch selectedMode {
            case .search:
                VStack(alignment: .leading, spacing: 12) {
                    Text("Find visually similar images")
                        .font(.title3.weight(.semibold))
                        .foregroundColor(.primary)
                    dropTarget
                    if !matchResults.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Top Matches")
                                .font(.headline)
                            ScrollViewReader { proxy in
                                ScrollView(.vertical, showsIndicators: true) {
                                    LazyVStack(alignment: .leading, spacing: 8) {
                                        Color.clear.frame(height: 0).id("top")
                                        ForEach(matchResults) { result in
                                        HStack(alignment: .top, spacing: 10) {
                                    ThumbnailView(url: result.url, size: 96)
                                    VStack(alignment: .leading, spacing: 2) {
                                        HStack(spacing: 6) {
                                            Button(action: { revealInFinder(result.url) }) {
                                                Text(result.url.lastPathComponent)
                                                    .font(.subheadline.weight(.medium))
                                                    .lineLimit(1)
                                                    .truncationMode(.middle)
                                            }
                                            .buttonStyle(.link)
                                            Text(String(format: "(%.3f)", result.distance))
                                                .font(.caption2)
                                                .foregroundColor(.secondary)
                                        }
                                        Text("\(result.width)×\(result.height) px • \(formatBytes(result.fileSize))")
                                            .font(.caption)
                                            .foregroundColor(.secondary)
                                        let root = containingRoot(for: result.url)
                                        HStack(spacing: 6) {
                                            Image(systemName: systemImageForFolder(root ?? result.url))
                                                .foregroundColor(.secondary)
                                            Text((root ?? result.url).lastPathComponent)
                                                .font(.caption)
                                                .foregroundColor(.secondary)
                                        }
                                    }
                                    Spacer()
                                }
                                .padding(12)
                                .background(.regularMaterial)
                                .cornerRadius(10)
                                .shadow(color: Color.black.opacity(0.06), radius: 6, x: 0, y: 2)
                                        }
                                    }
                                    .padding(.vertical, 8)
                                }
                                .frame(height: 360)
                                .onChange(of: matchResults) { _ in
                                    withAnimation { proxy.scrollTo("top", anchor: .top) }
                                }
                            }
                        }
                    }
                }

            case .importing:
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 12) {
                        Button(action: selectAndIndexFolder) {
                            Label("Select Folder or Drive…", systemImage: "externaldrive")
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
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
                    HStack(spacing: 8) {
                        Text("Database size:")
                        Text(formatBytes(databaseSizeBytes))
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
                                                        .font(.subheadline.weight(.medium))
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
                                                Label("Delete", systemImage: "trash")
                                            }
                                            .buttonStyle(.bordered)
                                            .tint(.red)
                                        }
                                        .padding(12)
                                        .background(.regularMaterial)
                                        .cornerRadius(10)
                                        .shadow(color: Color.black.opacity(0.05), radius: 4, x: 0, y: 1)
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
        .padding(20)
        .frame(minWidth: 560, minHeight: 640)
        .controlSize(.large)
        .font(.system(.body, design: .rounded))
        .overlay(alignment: .top) {
            if isToastVisible, let message = toastMessage {
                ToastView(message: message)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .zIndex(1)
                    .padding(.top, 12)
            }
        }
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
            databaseSizeBytes = computeDatabaseSize()
        }
    }

    /// A view representing the drop area. Accepts file URLs of images and
    /// triggers a search for the closest match upon drop.
    private var dropTarget: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 14)
                .fill(.ultraThinMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 14)
                        .stroke(Color.accentColor.opacity(0.35), lineWidth: 1)
                )
                .shadow(color: Color.black.opacity(0.06), radius: 8, x: 0, y: 2)
            if let preview = queryImage {
                Image(nsImage: preview)
                    .resizable()
                    .scaledToFit()
                    .padding(12)
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "photo.on.rectangle.angled")
                        .font(.system(size: 30, weight: .regular))
                        .foregroundColor(.accentColor)
                    Text("Drag & Drop or Click to Select")
                        .font(.headline)
                        .foregroundColor(.secondary)
                }
            }
        }
        .frame(height: 200)
        .onDrop(of: [UTType.fileURL.identifier], isTargeted: nil) { providers in
            guard let provider = providers.first else { return false }
            _ = provider.loadObject(ofClass: URL.self) { url, error in
                if let url = url {
                    searchForMatch(with: url)
                }
            }
            return true
        }
        .contentShape(Rectangle())
        .onTapGesture {
            selectAndSearchImage()
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

    /// Opens a file chooser and triggers a visual similarity search for the selected image.
    private func selectAndSearchImage() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.image]
        panel.prompt = "Search"
        if panel.runModal() == .OK, let url = panel.url {
            searchForMatch(with: url)
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
                showToast("Failed to enumerate folder.")
                statusMessage = ""
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
            if candidates.isEmpty {
                statusMessage = ""
                showToast("No new images to index.")
            } else {
                statusMessage = "Indexing images…"
            }
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
            var pixelWidth: Int64 = 0
            var pixelHeight: Int64 = 0
            var fileSizeBytes: Int64 = 0
            var dhashValue: UInt64 = 0
            autoreleasepool {
                do {
                    if let observation = try FeaturePrintService.generateFeaturePrint(for: fileURL) {
                        archivedData = try NSKeyedArchiver.archivedData(withRootObject: observation, requiringSecureCoding: true)
                    }
                    if let h = FeaturePrintService.computeDHash(for: fileURL) {
                        dhashValue = h
                    }
                    // Gather metadata
                    if let image = NSImage(contentsOf: fileURL) {
                        let rep = image.representations.first
                        pixelWidth = Int64(rep?.pixelsWide ?? 0)
                        pixelHeight = Int64(rep?.pixelsHigh ?? 0)
                    }
                    if let attrs = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
                       let size = attrs[.size] as? NSNumber {
                        fileSizeBytes = size.int64Value
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
                    record.width = pixelWidth
                    record.height = pixelHeight
                    record.fileSize = fileSizeBytes
                    record.dhash = Int64(bitPattern: dhashValue)
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
            if successfullyIndexed == 0 {
                showToast("No new images indexed.")
            } else {
                showToast("Indexed \(successfullyIndexed) of \(totalToIndex) images.")
            }
            statusMessage = ""
            isIndexing = false
            currentIndexingFolder = nil
            recomputeFolderCountsFromRecords()
            databaseSizeBytes = computeDatabaseSize()
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
            showToast("Deleted indexed folder: \(folderURL.lastPathComponent)")
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

    /// Returns the saved root folder that contains the provided file URL, if any.
    private func containingRoot(for fileURL: URL) -> URL? {
        let roots = IndexedFoldersStore.load().map { $0.standardizedFileURL }
        let filePath = fileURL.standardizedFileURL.deletingLastPathComponent().path
        for root in roots {
            let rootPath = root.path
            let rootWithSlash = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
            if filePath == rootPath || filePath.hasPrefix(rootWithSlash) {
                return root
            }
        }
        return nil
    }

    private func formatBytes(_ bytes: Int64) -> String {
        let units = ["B", "KB", "MB", "GB", "TB"]
        var size = Double(bytes)
        var unitIndex = 0
        while size >= 1024 && unitIndex < units.count - 1 {
            size /= 1024
            unitIndex += 1
        }
        if unitIndex == 0 {
            return String(format: "%.0f %@", size, units[unitIndex])
        } else {
            return String(format: "%.1f %@", size, units[unitIndex])
        }
    }

    private func revealInFinder(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    /// Computes the approximate on-disk size of the Core Data SQLite store.
    private func computeDatabaseSize() -> Int64 {
        let storeURL = PersistenceController.shared.container.persistentStoreDescriptions.first?.url
            ?? PersistenceController.shared.container.persistentStoreCoordinator.persistentStores.first?.url
        guard let baseURL = storeURL else { return 0 }
        // SQLite store comprises main file + -shm + -wal (if journaling enabled)
        let related = [baseURL, baseURL.appendingPathExtension("-shm"), baseURL.appendingPathExtension("-wal")]
        var total: Int64 = 0
        for url in related {
            if let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
               let size = attrs[.size] as? NSNumber {
                total += size.int64Value
            }
        }
        return total
    }

    /// Computes the top matching images for the given query URL.
    ///
    /// Reads the stored feature prints from Core Data, calculates the distance
    /// between the query image’s feature print and each stored print using
    /// `VNFeaturePrintObservation.computeDistance`, and records the smallest
    /// distance. Updates the UI state when finished.
    ///
    /// - Parameter queryURL: The URL of the image dropped onto the UI.
    private func searchForMatch(with queryURL: URL) {
        queryImage = FeaturePrintService.loadImage(from: queryURL)
        matchResults = []
        Task {
            do {
                guard let queryDhash = FeaturePrintService.computeDHash(for: queryURL) else {
                    await MainActor.run { showToast("Unable to compute dHash for query.") }
                    return
                }
                var topResults: [SearchResult] = []
                for record in records {
                    let recHash = UInt64(bitPattern: record.dhash)
                    if recHash == 0 { continue }
                    let dist = Float(FeaturePrintService.hammingDistance(queryDhash, recHash))
                    let result = SearchResult(
                        url: URL(fileURLWithPath: record.url),
                        width: record.width,
                        height: record.height,
                        fileSize: record.fileSize,
                        distance: dist
                    )
                    topResults.append(result)
                }
                topResults.sort { lhs, rhs in
                    if lhs.distance != rhs.distance { return lhs.distance < rhs.distance }
                    let lhsPixels = lhs.width * lhs.height
                    let rhsPixels = rhs.width * rhs.height
                    return lhsPixels > rhsPixels
                }
                let forced = topResults.filter { $0.distance <= 2.0 }
                let remaining = topResults.filter { $0.distance > 2.0 }
                let extraCount = max(10 - forced.count, 0)
                var finalResults = forced + Array(remaining.prefix(extraCount))
                // If there are more than 10 forced results, include them all as requested
                // (list can exceed 10 in that case)
                // Ensure deterministic order by distance, then resolution desc
                finalResults.sort { lhs, rhs in
                    if lhs.distance != rhs.distance { return lhs.distance < rhs.distance }
                    let lhsPixels = lhs.width * lhs.height
                    let rhsPixels = rhs.width * rhs.height
                    return lhsPixels > rhsPixels
                }
                topResults = finalResults
                if topResults.isEmpty {
                    await MainActor.run { showToast("No match found.") }
                } else {
                    await MainActor.run {
                        matchResults = topResults
                        if let best = topResults.first {
                            showToast(String(format: "Top match Hamming distance = %.0f", best.distance))
                        } else {
                            showToast("Matches found.")
                        }
                    }
                }
            }
        }
    }

    // MARK: - Toast helpers
    private func showToast(_ message: String, duration: TimeInterval = 2.0) {
        toastMessage = message
        withAnimation(.spring(response: 0.35, dampingFraction: 0.9)) {
            isToastVisible = true
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + duration) {
            withAnimation(.easeInOut(duration: 0.25)) {
                isToastVisible = false
            }
        }
    }
}

/// A lightweight toast view appearing at the top of the window.
private struct ToastView: View {
    let message: String
    @State private var isPresented: Bool = true

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "info.circle.fill")
                .foregroundColor(.accentColor)
            Text(message)
                .font(.callout.weight(.medium))
                .lineLimit(3)
                .multilineTextAlignment(.leading)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial)
        .cornerRadius(12)
        .shadow(color: Color.black.opacity(0.12), radius: 10, x: 0, y: 4)
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