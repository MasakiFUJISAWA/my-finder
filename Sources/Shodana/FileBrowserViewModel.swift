import AppKit
import Foundation
import NetFS
import UniformTypeIdentifiers

@MainActor
final class FileBrowserViewModel: ObservableObject {
    @Published private(set) var currentURL: URL
    @Published var addressText: String
    @Published private(set) var items: [FileItem] = []
    @Published var selectedIDs: Set<URL> = []
    @Published var showHiddenFiles = FileBrowserViewModel.loadShowHiddenFiles() {
        didSet {
            UserDefaults.standard.set(showHiddenFiles, forKey: Self.showHiddenFilesDefaultsKey)
            reload()
        }
    }
    @Published private(set) var sortColumn: FileSortColumn = .name
    @Published private(set) var sortAscending = true
    @Published var errorMessage: String?
    @Published var renameRequest: RenameRequest?
    @Published private(set) var pendingClipboardOperation: FileClipboardOperation?
    @Published private(set) var sidebarSections: [SidebarSection] = []
    @Published var viewMode: BrowserViewMode = .list
    @Published var contentMode: BrowserContentMode = .folder {
        didSet {
            guard oldValue != contentMode else {
                return
            }

            selectedIDs.removeAll()
            selectionAnchorURL = nil
        }
    }
    @Published var searchText = ""
    @Published private(set) var searchResults: [FileItem] = []
    @Published private(set) var isSearching = false
    @Published private(set) var hasPerformedSearch = false
    @Published private(set) var userFavoriteFolders: [URL] = []
    @Published private(set) var serverConnections: [ServerConnection] = []
    @Published var isConnectServerDialogPresented = false
    @Published var connectProtocol: RemoteConnectionKind = .smb
    @Published var connectServerAddress = "smb://"
    @Published var connectServerDisplayName = ""
    @Published var connectAWSProfile = ""
    @Published private(set) var awsProfiles: [String] = []
    @Published private(set) var appLanguageMode: AppLanguageMode = L10n.languageMode
    @Published private(set) var appAppearanceMode: AppAppearanceMode = AppAppearance.mode
    @Published private(set) var externalTools: [ExternalTool] = []
    @Published var isExternalToolsSettingsPresented = false
    @Published private(set) var launcherFolderShortcuts: [LauncherFolderShortcut] = []
    @Published var isLauncherFoldersSettingsPresented = false
    @Published var groupMode: FileGroupMode = .none

    private static let showHiddenFilesDefaultsKey = "Shodana.showHiddenFiles"
    private static let legacyShowHiddenFilesDefaultsKeys = ["Mihako.showHiddenFiles"]

    private let fileManager = FileManager.default
    private let userFavoritesDefaultsKey = "Shodana.userFavoriteFolders"
    private let legacyUserFavoritesDefaultsKeys = ["Mihako.userFavoriteFolders", "My" + "Finder.userFavoriteFolders"]
    private let serverConnectionsDefaultsKey = "Shodana.serverConnections"
    private let legacyServerConnectionsDefaultsKeys = ["Mihako.serverConnections", "My" + "Finder.serverConnections"]
    private let sidebarLocationOrderDefaultsKey = "Shodana.sidebarLocationOrder"
    private let legacySidebarLocationOrderDefaultsKeys = ["Mihako.sidebarLocationOrder"]
    private let externalToolsDefaultsKey = "Shodana.externalTools"
    private let legacyExternalToolsDefaultsKeys = ["Mihako.externalTools"]
    private var history: [URL]
    private var historyIndex = 0
    private var selectionAnchorURL: URL?
    private var reconnectingServerIDs: Set<String> = []
    private var sidebarLocationOrderIDs: [String] = []
    private var remoteReloadTask: Task<Void, Never>?
    private var searchTask: Task<Void, Never>?

    private enum TerminalApp {
        case terminal
        case iTerm
    }

    private var iTermApplicationURL: URL? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.googlecode.iterm2")
    }

    private var terminalApplicationURL: URL? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Terminal")
            ?? URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app")
    }

    init(startURL: URL = FileManager.default.homeDirectoryForCurrentUser) {
        let initialURL = startURL.standardizedFileURL
        currentURL = initialURL
        addressText = initialURL.path
        history = [initialURL]
        userFavoriteFolders = Self.loadUserFavoriteFolders(
            defaultsKey: userFavoritesDefaultsKey,
            legacyDefaultsKeys: legacyUserFavoritesDefaultsKeys
        )
        serverConnections = Self.loadServerConnections(
            defaultsKey: serverConnectionsDefaultsKey,
            legacyDefaultsKeys: legacyServerConnectionsDefaultsKeys
        )
        sidebarLocationOrderIDs = Self.loadSidebarLocationOrder(
            defaultsKey: sidebarLocationOrderDefaultsKey,
            legacyDefaultsKeys: legacySidebarLocationOrderDefaultsKeys
        )
        externalTools = Self.loadExternalTools(
            defaultsKey: externalToolsDefaultsKey,
            legacyDefaultsKeys: legacyExternalToolsDefaultsKeys
        )
        launcherFolderShortcuts = LauncherFolderShortcutStore.load()
        refreshSidebarLocations()
        reload()
        reconnectSavedServers()
    }

    var canGoBack: Bool {
        historyIndex > 0
    }

    var canGoForward: Bool {
        historyIndex < history.count - 1
    }

    var canGoUp: Bool {
        if isCurrentSFTP {
            return SFTPClient.remotePath(for: currentURL) != "/"
        }

        if isCurrentS3 {
            return !S3Client.prefix(for: currentURL).isEmpty
        }

        return currentURL.path != "/"
    }

    var displayedItems: [FileItem] {
        contentMode == .search ? searchResults : items
    }

    var selectedItems: [FileItem] {
        displayedItems.filter { selectedIDs.contains($0.url) }
    }

    var selectedURLs: [URL] {
        selectedItems.map(\.url)
    }

    var groupedItems: [FileItemGroup] {
        groupedItems(for: displayedItems)
    }

    var selectedFolderURL: URL? {
        guard !isCurrentRemote else {
            return nil
        }

        guard selectedIDs.count == 1,
              let item = selectedItems.first,
              item.canNavigateInto else {
            return nil
        }

        return item.url
    }

    var isITermAvailable: Bool {
        iTermApplicationURL != nil
    }

    var isTextInputActive: Bool {
        guard let firstResponder = NSApp.keyWindow?.firstResponder else {
            return false
        }

        return firstResponder.isEditableTextInputResponder
    }

    var canCutOrCopySelection: Bool {
        !selectedIDs.isEmpty
    }

    var isCurrentSFTP: Bool {
        SFTPClient.isSFTPURL(currentURL)
    }

    var isCurrentS3: Bool {
        S3Client.isS3URL(currentURL)
    }

    var isCurrentRemote: Bool {
        isCurrentSFTP || isCurrentS3
    }

    var currentDisplayAddress: String {
        displayString(for: currentURL)
    }

    var breadcrumbs: [Breadcrumb] {
        if isCurrentSFTP {
            return sftpBreadcrumbs()
        }

        if isCurrentS3 {
            return s3Breadcrumbs()
        }

        var result: [Breadcrumb] = []
        var path = ""

        for component in currentURL.pathComponents {
            if component == "/" {
                path = "/"
                result.append(Breadcrumb(title: Self.rootVolumeTitle(), url: URL(fileURLWithPath: "/", isDirectory: true)))
            } else {
                path = (path as NSString).appendingPathComponent(component)
                result.append(Breadcrumb(title: component, url: URL(fileURLWithPath: path, isDirectory: true)))
            }
        }

        return result
    }

    private func s3Breadcrumbs() -> [Breadcrumb] {
        let bucketTitle = currentURL.host(percentEncoded: false) ?? "S3"
        var result = [
            Breadcrumb(title: bucketTitle, url: S3Client.url(bySettingPrefix: "", on: currentURL))
        ]
        let prefix = S3Client.prefix(for: currentURL).trimmingTrailingSlash

        guard !prefix.isEmpty else {
            return result
        }

        var accumulatedPrefix = ""
        for component in prefix.split(separator: "/").map(String.init) {
            accumulatedPrefix = accumulatedPrefix.isEmpty ? component : "\(accumulatedPrefix)/\(component)"
            result.append(
                Breadcrumb(
                    title: component,
                    url: S3Client.url(bySettingPrefix: "\(accumulatedPrefix)/", on: currentURL)
                )
            )
        }

        return result
    }

    private func sftpBreadcrumbs() -> [Breadcrumb] {
        let path = SFTPClient.remotePath(for: currentURL)
        let hostTitle = currentURL.host(percentEncoded: false) ?? "SFTP"
        var result = [
            Breadcrumb(title: hostTitle, url: SFTPClient.url(bySettingPath: "/", on: currentURL))
        ]

        guard path != "/" else {
            return result
        }

        var accumulatedPath = ""
        for component in path.split(separator: "/").map(String.init) {
            accumulatedPath += "/\(component)"
            result.append(
                Breadcrumb(
                    title: component,
                    url: SFTPClient.url(bySettingPath: accumulatedPath, on: currentURL)
                )
            )
        }

        return result
    }

    func reload() {
        refreshSidebarLocations()

        if isCurrentSFTP {
            reloadSFTPDirectory()
            return
        }

        if isCurrentS3 {
            reloadS3Directory()
            return
        }

        remoteReloadTask?.cancel()

        do {
            items = sortedItems(try loadLocalItems(at: currentURL))
            selectedIDs = selectedIDs.filter { selectedURL in
                items.contains { $0.url == selectedURL }
            }

            if let selectionAnchorURL, !items.contains(where: { $0.url == selectionAnchorURL }) {
                self.selectionAnchorURL = firstSelectedURLInDisplayOrder()
            }
        } catch {
            items = []
            selectedIDs.removeAll()
            selectionAnchorURL = nil
            presentError(error, action: "Read folder")
        }
    }

    private func loadLocalItems(at url: URL) throws -> [FileItem] {
        let keys: [URLResourceKey] = [
            .isDirectoryKey,
            .isPackageKey,
            .fileSizeKey,
            .totalFileAllocatedSizeKey,
            .contentModificationDateKey,
            .localizedTypeDescriptionKey,
            .isHiddenKey,
            .localizedNameKey
        ]

        let options: FileManager.DirectoryEnumerationOptions = showHiddenFiles ? [] : [.skipsHiddenFiles]
        let urls = try fileManager.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: keys,
            options: options
        )

        return try urls.map(FileItem.load)
    }

    func itemsForDisplay(at url: URL) async throws -> [FileItem] {
        if SFTPClient.isSFTPURL(url) {
            let result = try await SFTPClient.listDirectory(at: url, showHiddenFiles: showHiddenFiles)
            return sortedItems(result.items)
        }

        if S3Client.isS3URL(url) {
            let result = try await S3Client.listDirectory(at: url, showHiddenFiles: showHiddenFiles)
            return sortedItems(result.items)
        }

        return try sortedItems(loadLocalItems(at: url))
    }

    func groupedItems(for values: [FileItem]) -> [FileItemGroup] {
        guard groupMode != .none else {
            return [
                FileItemGroup(
                    id: FileGroupMode.none.rawValue,
                    title: "",
                    items: values
                )
            ]
        }

        var groups: [FileItemGroup] = []
        var indexesByID: [String: Int] = [:]

        for item in values {
            let descriptor = groupDescriptor(for: item)

            if let index = indexesByID[descriptor.id] {
                let group = groups[index]
                groups[index] = FileItemGroup(
                    id: group.id,
                    title: group.title,
                    items: group.items + [item]
                )
            } else {
                indexesByID[descriptor.id] = groups.count
                groups.append(
                    FileItemGroup(
                        id: descriptor.id,
                        title: descriptor.title,
                        items: [item]
                    )
                )
            }
        }

        return groups.sorted { left, right in
            left.id.localizedStandardCompare(right.id) == .orderedAscending
        }
    }

    var emptyListMessage: String {
        guard contentMode == .search else {
            return L10n.string("Empty Folder")
        }

        if isSearching {
            return L10n.string("Searching...")
        }

        if searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !hasPerformedSearch {
            return L10n.string("Enter a search term")
        }

        return L10n.string("No Results")
    }

    func performSearch() {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        contentMode = .search
        searchTask?.cancel()
        selectedIDs.removeAll()
        selectionAnchorURL = nil

        guard !query.isEmpty else {
            searchResults = []
            isSearching = false
            hasPerformedSearch = false
            return
        }

        guard let rootURL = searchRootURLFromAddress() else {
            searchResults = []
            isSearching = false
            hasPerformedSearch = false
            return
        }

        hasPerformedSearch = true
        addressText = displayString(for: rootURL)

        if SFTPClient.isSFTPURL(rootURL) || S3Client.isS3URL(rootURL) {
            isSearching = true
            searchTask = Task { [weak self] in
                do {
                    let rootItems = try await self?.itemsForDisplay(at: rootURL) ?? []
                    let results = rootItems.filter { item in
                        Self.matchesSearch(query: query, value: item.displayName)
                    }

                    await MainActor.run { [weak self] in
                        guard let self, !Task.isCancelled else {
                            return
                        }

                        self.searchResults = self.sortedItems(results)
                        self.isSearching = false
                    }
                } catch {
                    await MainActor.run { [weak self] in
                        guard let self, !Task.isCancelled else {
                            return
                        }

                        self.searchResults = []
                        self.isSearching = false
                        self.presentError(error, action: "Search")
                    }
                }
            }
            return
        }

        let shouldShowHiddenFiles = showHiddenFiles
        isSearching = true

        searchTask = Task { [weak self] in
            do {
                let results = try await Self.searchLocalItems(
                    matching: query,
                    in: rootURL,
                    showHiddenFiles: shouldShowHiddenFiles
                )

                await MainActor.run {
                    guard let self, !Task.isCancelled else {
                        return
                    }

                    self.searchResults = self.sortedItems(results)
                    self.isSearching = false
                }
            } catch is CancellationError {
                await MainActor.run {
                    guard let self, !Task.isCancelled else {
                        return
                    }

                    self.isSearching = false
                }
            } catch {
                await MainActor.run {
                    guard let self, !Task.isCancelled else {
                        return
                    }

                    self.searchResults = []
                    self.isSearching = false
                    self.presentError(error, action: "Search")
                }
            }
        }
    }

    private func searchRootURLFromAddress() -> URL? {
        let rawPath = addressText.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !rawPath.isEmpty else {
            addressText = displayString(for: currentURL)
            return currentURL
        }

        if rawPath.lowercased().hasPrefix("sftp://") {
            guard let targetURL = URL(string: rawPath) else {
                presentMessage("Invalid SFTP URL: \(rawPath)")
                return nil
            }

            return targetURL
        }

        if rawPath.lowercased().hasPrefix("s3://") {
            guard let targetURL = URL(string: rawPath) else {
                presentMessage("Invalid S3 URL: \(rawPath)")
                return nil
            }

            return targetURL
        }

        if isCurrentSFTP {
            let targetPath = rawPath.hasPrefix("/")
                ? rawPath
                : SFTPClient.remotePath(for: currentURL).appendingRemotePathComponent(rawPath)
            return SFTPClient.url(bySettingPath: targetPath, on: currentURL)
        }

        if isCurrentS3 {
            let currentPrefix = S3Client.directoryPrefix(for: currentURL)
            let targetPrefix = rawPath.hasPrefix("/")
                ? String(rawPath.drop { $0 == "/" })
                : currentPrefix.appendingS3PrefixComponent(rawPath)
            return S3Client.url(bySettingPrefix: targetPrefix, on: currentURL)
        }

        let expandedPath = (rawPath as NSString).expandingTildeInPath
        let targetURL = expandedPath.hasPrefix("/")
            ? URL(fileURLWithPath: expandedPath, isDirectory: true)
            : currentURL.appendingPathComponent(expandedPath, isDirectory: true)
        let standardizedURL = targetURL.standardizedFileURL
        var isDirectory: ObjCBool = false

        guard fileManager.fileExists(atPath: standardizedURL.path, isDirectory: &isDirectory) else {
            presentMessage("Path does not exist: \(standardizedURL.path)")
            return nil
        }

        guard isDirectory.boolValue else {
            presentMessage("Search path is not a folder: \(standardizedURL.path)")
            return nil
        }

        return standardizedURL
    }

    private nonisolated static func searchLocalItems(
        matching query: String,
        in rootURL: URL,
        showHiddenFiles: Bool
    ) async throws -> [FileItem] {
        try await Task.detached(priority: .userInitiated) {
            if let spotlightItems = try? searchLocalItemsWithSpotlight(
                matching: query,
                in: rootURL,
                showHiddenFiles: showHiddenFiles
            ),
               !spotlightItems.isEmpty {
                return spotlightItems
            }

            let keys: [URLResourceKey] = [
                .isDirectoryKey,
                .isPackageKey,
                .fileSizeKey,
                .totalFileAllocatedSizeKey,
                .contentModificationDateKey,
                .localizedTypeDescriptionKey,
                .isHiddenKey,
                .localizedNameKey
            ]
            var options: FileManager.DirectoryEnumerationOptions = [.skipsPackageDescendants]

            if !showHiddenFiles {
                options.insert(.skipsHiddenFiles)
            }

            let enumerator = FileManager.default.enumerator(
                at: rootURL,
                includingPropertiesForKeys: keys,
                options: options
            ) { _, _ in
                true
            }
            var results: [FileItem] = []

            while let url = enumerator?.nextObject() as? URL {
                try Task.checkCancellation()

                let values = try? url.resourceValues(forKeys: [.localizedNameKey])
                let displayName = values?.localizedName ?? url.lastPathComponent

                guard matchesSearch(query: query, value: displayName),
                      let item = try? FileItem.load(from: url) else {
                    continue
                }

                results.append(item)
            }

            return results
        }.value
    }

    private nonisolated static func searchLocalItemsWithSpotlight(
        matching query: String,
        in rootURL: URL,
        showHiddenFiles: Bool
    ) throws -> [FileItem] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/mdfind")
        process.arguments = [
            "-0",
            "-onlyin",
            rootURL.path,
            spotlightPredicate(for: query)
        ]

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            throw CocoaError(.executableLoad)
        }

        return outputPipe.fileHandleForReading
            .readDataToEndOfFile()
            .split(separator: 0)
            .compactMap { bytes -> FileItem? in
                guard let path = String(data: Data(bytes), encoding: .utf8) else {
                    return nil
                }

                let url = URL(fileURLWithPath: path)

                guard let item = try? FileItem.load(from: url),
                      showHiddenFiles || !item.isHidden else {
                    return nil
                }

                return item
            }
    }

    private nonisolated static func spotlightPredicate(for query: String) -> String {
        let escapedQuery = query
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")

        return """
        kMDItemFSName == "*\(escapedQuery)*"cd || kMDItemDisplayName == "*\(escapedQuery)*"cd
        """
    }

    private nonisolated static func matchesSearch(query: String, value: String) -> Bool {
        value.range(
            of: query,
            options: [.caseInsensitive, .diacriticInsensitive]
        ) != nil
    }

    private func reloadSFTPDirectory() {
        let requestedURL = currentURL
        let shouldShowHiddenFiles = showHiddenFiles
        remoteReloadTask?.cancel()
        items = []

        remoteReloadTask = Task { [weak self] in
            do {
                let result = try await SFTPClient.listDirectory(
                    at: requestedURL,
                    showHiddenFiles: shouldShowHiddenFiles
                )

                await MainActor.run {
                    guard let self, !Task.isCancelled else {
                        return
                    }

                    self.currentURL = result.url
                    self.addressText = self.displayString(for: result.url)
                    self.items = self.sortedItems(result.items)
                    self.selectedIDs = self.selectedIDs.filter { selectedURL in
                        self.items.contains { $0.url == selectedURL }
                    }

                    if let selectionAnchorURL = self.selectionAnchorURL,
                       !self.items.contains(where: { $0.url == selectionAnchorURL }) {
                        self.selectionAnchorURL = self.firstSelectedURLInDisplayOrder()
                    }

                    if self.history.indices.contains(self.historyIndex),
                       self.history[self.historyIndex] == requestedURL {
                        self.history[self.historyIndex] = result.url
                    }

                    self.markServerConnectionAvailable(result.url)
                }
            } catch {
                await MainActor.run {
                    guard let self, !Task.isCancelled else {
                        return
                    }

                    self.items = []
                    self.selectedIDs.removeAll()
                    self.selectionAnchorURL = nil
                    self.markServerConnectionUnavailable(requestedURL)
                    self.presentError(error, action: "Read SFTP folder")
                }
            }
        }
    }

    private func reloadS3Directory() {
        let requestedURL = currentURL
        let shouldShowHiddenFiles = showHiddenFiles
        remoteReloadTask?.cancel()
        items = []

        remoteReloadTask = Task { [weak self] in
            do {
                let result = try await S3Client.listDirectory(
                    at: requestedURL,
                    showHiddenFiles: shouldShowHiddenFiles
                )

                await MainActor.run {
                    guard let self, !Task.isCancelled else {
                        return
                    }

                    self.currentURL = result.url
                    self.addressText = self.displayString(for: result.url)
                    self.items = self.sortedItems(result.items)
                    self.selectedIDs = self.selectedIDs.filter { selectedURL in
                        self.items.contains { $0.url == selectedURL }
                    }

                    if let selectionAnchorURL = self.selectionAnchorURL,
                       !self.items.contains(where: { $0.url == selectionAnchorURL }) {
                        self.selectionAnchorURL = self.firstSelectedURLInDisplayOrder()
                    }

                    if self.history.indices.contains(self.historyIndex),
                       self.history[self.historyIndex] == requestedURL {
                        self.history[self.historyIndex] = result.url
                    }

                    self.markServerConnectionAvailable(result.url)
                }
            } catch {
                await MainActor.run {
                    guard let self, !Task.isCancelled else {
                        return
                    }

                    self.items = []
                    self.selectedIDs.removeAll()
                    self.selectionAnchorURL = nil
                    self.markServerConnectionUnavailable(requestedURL)
                    self.presentError(error, action: "Read S3 folder")
                }
            }
        }
    }

    func submitAddress() {
        let rawPath = addressText.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !rawPath.isEmpty else {
            addressText = displayString(for: currentURL)
            return
        }

        if rawPath.lowercased().hasPrefix("sftp://") {
            guard let targetURL = URL(string: rawPath) else {
                addressText = displayString(for: currentURL)
                presentMessage("Invalid SFTP URL: \(rawPath)")
                return
            }

            navigate(to: targetURL)
            return
        }

        if rawPath.lowercased().hasPrefix("s3://") {
            guard let targetURL = URL(string: rawPath) else {
                addressText = displayString(for: currentURL)
                presentMessage("Invalid S3 URL: \(rawPath)")
                return
            }

            navigate(to: targetURL)
            return
        }

        if isCurrentSFTP {
            let targetPath = rawPath.hasPrefix("/")
                ? rawPath
                : SFTPClient.remotePath(for: currentURL).appendingRemotePathComponent(rawPath)
            navigate(to: SFTPClient.url(bySettingPath: targetPath, on: currentURL))
            return
        }

        if isCurrentS3 {
            let currentPrefix = S3Client.directoryPrefix(for: currentURL)
            let targetPrefix = rawPath.hasPrefix("/")
                ? String(rawPath.drop { $0 == "/" })
                : currentPrefix.appendingS3PrefixComponent(rawPath)
            navigate(to: S3Client.url(bySettingPrefix: targetPrefix, on: currentURL))
            return
        }

        let expandedPath = (rawPath as NSString).expandingTildeInPath
        let targetURL: URL

        if expandedPath.hasPrefix("/") {
            targetURL = URL(fileURLWithPath: expandedPath)
        } else {
            targetURL = currentURL.appendingPathComponent(expandedPath)
        }

        navigate(to: targetURL)
    }

    func navigate(to url: URL, recordHistory: Bool = true) {
        contentMode = .folder
        searchTask?.cancel()
        isSearching = false

        if SFTPClient.isSFTPURL(url) {
            navigateToSFTP(url, recordHistory: recordHistory)
            return
        }

        if S3Client.isS3URL(url) {
            navigateToS3(url, recordHistory: recordHistory)
            return
        }

        let targetURL = url.standardizedFileURL
        var isDirectory: ObjCBool = false

        guard fileManager.fileExists(atPath: targetURL.path, isDirectory: &isDirectory) else {
            addressText = displayString(for: currentURL)
            presentMessage("Path does not exist: \(targetURL.path)")
            return
        }

        guard isDirectory.boolValue else {
            NSWorkspace.shared.open(targetURL)
            addressText = displayString(for: currentURL)
            return
        }

        currentURL = targetURL
        addressText = displayString(for: targetURL)
        selectedIDs.removeAll()
        selectionAnchorURL = nil

        if recordHistory {
            if historyIndex < history.count - 1 {
                history.removeSubrange((historyIndex + 1)..<history.count)
            }

            if history.last != targetURL {
                history.append(targetURL)
                historyIndex = history.count - 1
            }
        }

        reload()
    }

    func openExternalDestination(_ url: URL) {
        if SFTPClient.isSFTPURL(url) || S3Client.isS3URL(url) {
            navigate(to: url)
            return
        }

        let targetURL = url.standardizedFileURL
        var isDirectory: ObjCBool = false

        guard fileManager.fileExists(atPath: targetURL.path, isDirectory: &isDirectory) else {
            presentMessage("Path does not exist: \(targetURL.path)")
            return
        }

        if isDirectory.boolValue {
            navigate(to: targetURL)
        } else {
            navigate(to: targetURL.deletingLastPathComponent())
            NSWorkspace.shared.open(targetURL)
        }
    }

    private func resolvedAliasOrSymlinkDestination(for url: URL) -> URL? {
        guard !isRemoteURL(url),
              let values = try? url.resourceValues(forKeys: [.isAliasFileKey, .isSymbolicLinkKey]) else {
            return nil
        }

        if values.isAliasFile == true {
            return try? URL(resolvingAliasFileAt: url, options: [])
        }

        if values.isSymbolicLink == true {
            let resolvedURL = url.resolvingSymlinksInPath()
            return resolvedURL == url ? nil : resolvedURL
        }

        return nil
    }

    private func openResolvedLocalDestination(_ resolvedURL: URL, fallbackURL: URL) {
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isPackageKey]
        let values = try? resolvedURL.resourceValues(forKeys: keys)

        if values?.isDirectory == true, values?.isPackage != true {
            navigate(to: resolvedURL)
            return
        }

        if fileManager.fileExists(atPath: resolvedURL.path) {
            NSWorkspace.shared.open(resolvedURL)
        } else {
            NSWorkspace.shared.open(fallbackURL)
        }
    }

    private func navigateToSFTP(_ url: URL, recordHistory: Bool) {
        currentURL = url
        addressText = displayString(for: url)
        selectedIDs.removeAll()
        selectionAnchorURL = nil

        if recordHistory {
            if historyIndex < history.count - 1 {
                history.removeSubrange((historyIndex + 1)..<history.count)
            }

            if history.last != url {
                history.append(url)
                historyIndex = history.count - 1
            }
        }

        reload()
    }

    private func navigateToS3(_ url: URL, recordHistory: Bool) {
        currentURL = url
        addressText = displayString(for: url)
        selectedIDs.removeAll()
        selectionAnchorURL = nil

        if recordHistory {
            if historyIndex < history.count - 1 {
                history.removeSubrange((historyIndex + 1)..<history.count)
            }

            if history.last != url {
                history.append(url)
                historyIndex = history.count - 1
            }
        }

        reload()
    }

    func goBack() {
        guard canGoBack else {
            return
        }

        historyIndex -= 1
        navigate(to: history[historyIndex], recordHistory: false)
    }

    func goForward() {
        guard canGoForward else {
            return
        }

        historyIndex += 1
        navigate(to: history[historyIndex], recordHistory: false)
    }

    func goUp() {
        guard canGoUp else {
            return
        }

        if isCurrentSFTP {
            navigate(to: SFTPClient.parentURL(for: currentURL))
        } else if isCurrentS3 {
            navigate(to: S3Client.parentURL(for: currentURL))
        } else {
            navigate(to: currentURL.deletingLastPathComponent())
        }
    }

    func open(_ item: FileItem) {
        if let resolvedURL = resolvedAliasOrSymlinkDestination(for: item.url) {
            openResolvedLocalDestination(resolvedURL, fallbackURL: item.url)
        } else if item.canNavigateInto {
            navigate(to: item.url)
        } else if SFTPClient.isSFTPURL(item.url) {
            downloadAndOpen(item.url)
        } else if S3Client.isS3URL(item.url) {
            downloadAndOpenS3(item.url)
        } else {
            NSWorkspace.shared.open(item.url)
        }
    }

    func showPackageContents(_ item: FileItem) {
        guard item.isPackage, !isRemoteURL(item.url) else {
            return
        }

        navigate(to: item.url)
    }

    func openSelected() {
        guard let item = selectedItems.first else {
            return
        }

        open(item)
    }

    func open(_ location: SidebarLocation) {
        if location.isUnavailable, let connectionURL = location.connectionURL {
            let kind = remoteConnectionKind(for: connectionURL.absoluteString) ?? .smb
            let connection = serverConnection(kind: kind, url: connectionURL)
            mountServerConnection(
                kind: kind,
                url: connectionURL,
                displayName: connection?.displayName,
                awsProfile: connection?.awsProfile,
                silentFailure: true
            )
            return
        }

        navigate(to: location.url)
    }

    func select(_ item: FileItem) {
        select(item.url)
    }

    func selectOnly(_ url: URL) {
        selectedIDs = [url]
        selectionAnchorURL = url
    }

    func select(_ url: URL) {
        let modifierFlags = NSApp.currentEvent?.modifierFlags ?? []
        activateFilePane()

        if modifierFlags.contains(.command) {
            if selectedIDs.contains(url) {
                selectedIDs.remove(url)

                if selectionAnchorURL == url {
                    selectionAnchorURL = firstSelectedURLInDisplayOrder()
                }
            } else {
                selectedIDs.insert(url)
                selectionAnchorURL = url
            }
        } else if modifierFlags.contains(.shift) {
            selectRange(endingAt: url)
        } else {
            selectedIDs = [url]
            selectionAnchorURL = url
        }
    }

    func activateFilePane() {
        NSApp.keyWindow?.makeFirstResponder(nil)
    }

    private func selectRange(endingAt url: URL) {
        let anchorURL = selectionAnchorURL
            ?? firstSelectedURLInDisplayOrder()
            ?? url

        let selectableItems = displayedItems

        guard let anchorIndex = selectableItems.firstIndex(where: { $0.url == anchorURL }),
              let endIndex = selectableItems.firstIndex(where: { $0.url == url }) else {
            selectOnly(url)
            return
        }

        let bounds = anchorIndex <= endIndex
            ? anchorIndex...endIndex
            : endIndex...anchorIndex

        selectedIDs = Set(selectableItems[bounds].map(\.url))
        selectionAnchorURL = anchorURL
    }

    private func firstSelectedURLInDisplayOrder() -> URL? {
        displayedItems.first { selectedIDs.contains($0.url) }?.url
    }

    func dragProvider(for item: FileItem) -> NSItemProvider {
        let draggedURLs = draggedURLs(for: item)

        let provider: NSItemProvider
        let itemURLString = item.url.absoluteString

        if SFTPClient.isSFTPURL(item.url) {
            provider = NSItemProvider()
            provider.registerDataRepresentation(
                forTypeIdentifier: ShodanaTransferType.sftpURL,
                visibility: .all
            ) { completion in
                completion(itemURLString.data(using: .utf8), nil)
                return nil
            }
            provider.registerDataRepresentation(
                forTypeIdentifier: UTType.url.identifier,
                visibility: .all
            ) { completion in
                completion(itemURLString.data(using: .utf8), nil)
                return nil
            }
        } else if S3Client.isS3URL(item.url) {
            provider = NSItemProvider()
            provider.registerDataRepresentation(
                forTypeIdentifier: ShodanaTransferType.s3URL,
                visibility: .all
            ) { completion in
                completion(itemURLString.data(using: .utf8), nil)
                return nil
            }
            provider.registerDataRepresentation(
                forTypeIdentifier: UTType.url.identifier,
                visibility: .all
            ) { completion in
                completion(itemURLString.data(using: .utf8), nil)
                return nil
            }
        } else {
            provider = NSItemProvider(object: item.url as NSURL)
        }

        provider.suggestedName = item.displayName
        registerDraggedURLList(draggedURLs, on: provider)

        guard !isRemoteURL(item.url) else {
            return provider
        }

        provider.registerDataRepresentation(
            forTypeIdentifier: UTType.fileURL.identifier,
            visibility: .all
        ) { completion in
            completion(itemURLString.data(using: .utf8), nil)
            return nil
        }

        provider.registerDataRepresentation(
            forTypeIdentifier: UTType.url.identifier,
            visibility: .all
        ) { completion in
            completion(itemURLString.data(using: .utf8), nil)
            return nil
        }

        return provider
    }

    func draggedURLsForDraggingSession(for item: FileItem) -> [URL] {
        draggedURLs(for: item)
    }

    func pasteboardWriter(forDraggedURL url: URL) -> NSPasteboardWriting {
        guard isRemoteURL(url) else {
            return url as NSURL
        }

        let pasteboardItem = NSPasteboardItem()
        let urlString = url.absoluteString

        if SFTPClient.isSFTPURL(url) {
            pasteboardItem.setString(urlString, forType: NSPasteboard.PasteboardType(ShodanaTransferType.sftpURL))
        } else if S3Client.isS3URL(url) {
            pasteboardItem.setString(urlString, forType: NSPasteboard.PasteboardType(ShodanaTransferType.s3URL))
        }

        pasteboardItem.setString(urlString, forType: .URL)
        pasteboardItem.setString(urlString, forType: .string)
        return pasteboardItem
    }

    func dragImage(forDraggedURL url: URL) -> NSImage {
        if isRemoteURL(url) {
            let image = NSImage(systemSymbolName: S3Client.isS3URL(url) ? "shippingbox" : "terminal", accessibilityDescription: nil)
                ?? NSImage(size: NSSize(width: 32, height: 32))
            image.size = NSSize(width: 32, height: 32)
            return image
        }

        let image = NSWorkspace.shared.icon(forFile: url.path)
        image.size = NSSize(width: 32, height: 32)
        return image
    }

    private func draggedURLs(for item: FileItem) -> [URL] {
        if selectedIDs.contains(item.url) {
            let selectedURLsInDisplayOrder = displayedItems
                .filter { selectedIDs.contains($0.url) }
                .map(\.url)

            if !selectedURLsInDisplayOrder.isEmpty {
                return selectedURLsInDisplayOrder
            }
        }

        selectOnly(item.url)
        return [item.url]
    }

    private func registerDraggedURLList(_ urls: [URL], on provider: NSItemProvider) {
        guard !urls.isEmpty else {
            return
        }

        let urlListData = urls
            .map(\.absoluteString)
            .joined(separator: "\n")
            .data(using: .utf8)

        provider.registerDataRepresentation(
            forTypeIdentifier: ShodanaTransferType.fileURLs,
            visibility: .all
        ) { completion in
            completion(urlListData, nil)
            return nil
        }

        let localURLs = urls.filter { !self.isRemoteURL($0) }

        guard !localURLs.isEmpty,
              let filenamesData = Self.filenamesPasteboardData(for: localURLs) else {
            return
        }

        provider.registerDataRepresentation(
            forTypeIdentifier: ShodanaTransferType.filenamesPasteboard,
            visibility: .all
        ) { completion in
            completion(filenamesData, nil)
            return nil
        }
    }

    func dropItems(from providers: [NSItemProvider], into destinationFolder: URL) -> Bool {
        var acceptedDrop = false

        for provider in providers {
            guard let typeIdentifier = ShodanaTransferType.urlDropTypeIdentifiers.first(where: {
                provider.hasItemConformingToTypeIdentifier($0)
            }) else {
                continue
            }

            acceptedDrop = true
            loadDroppedURL(from: provider, typeIdentifier: typeIdentifier, into: destinationFolder)
        }

        return acceptedDrop
    }

    private func loadDroppedURL(
        from provider: NSItemProvider,
        typeIdentifier: String,
        into destinationFolder: URL
    ) {
        if typeIdentifier == ShodanaTransferType.fileURLs || typeIdentifier == ShodanaTransferType.filenamesPasteboard {
            provider.loadDataRepresentation(forTypeIdentifier: typeIdentifier) { [weak self] data, error in
                let droppedURLs: [URL]

                if typeIdentifier == ShodanaTransferType.filenamesPasteboard {
                    droppedURLs = data.flatMap(Self.urlsFromFilenamesPasteboardData) ?? []
                } else {
                    droppedURLs = data
                        .flatMap { String(data: $0, encoding: .utf8) }
                        .map(Self.urlsFromDroppedURLList) ?? []
                }

                Task { @MainActor in
                    self?.dropURLs(
                        droppedURLs,
                        errorMessage: droppedURLs.isEmpty ? error?.localizedDescription : nil,
                        into: destinationFolder
                    )
                }
            }
            return
        }

        guard typeIdentifier == UTType.fileURL.identifier else {
            provider.loadDataRepresentation(forTypeIdentifier: typeIdentifier) { [weak self] data, error in
                let droppedURL = data
                    .flatMap { String(data: $0, encoding: .utf8) }
                    .flatMap(Self.url(fromDroppedString:))

                Task { @MainActor in
                    self?.dropItem(droppedURL, errorMessage: droppedURL == nil ? error?.localizedDescription : nil, into: destinationFolder)
                }
            }
            return
        }

        provider.loadItem(forTypeIdentifier: typeIdentifier, options: nil) { [weak self] item, itemError in
            let droppedURL = Self.url(fromDroppedItem: item)

            Task { @MainActor in
                self?.dropItem(droppedURL, errorMessage: droppedURL == nil ? itemError?.localizedDescription : nil, into: destinationFolder)
            }
        }
    }

    func sort(by column: FileSortColumn) {
        if sortColumn == column {
            sortAscending.toggle()
        } else {
            sortColumn = column
            sortAscending = true
        }

        items = sortedItems(items)
        searchResults = sortedItems(searchResults)
    }

    func createFolder() {
        if isCurrentSFTP {
            createSFTPFolder()
            return
        }

        if isCurrentS3 {
            createS3Folder()
            return
        }

        let folderURL = uniqueURL(
            in: currentURL,
            baseName: "New Folder",
            pathExtension: "",
            copyStyle: false
        )

        do {
            try fileManager.createDirectory(at: folderURL, withIntermediateDirectories: false)
            reload()
            selectOnly(folderURL)
            renameRequest = RenameRequest(url: folderURL, currentName: folderURL.lastPathComponent)
        } catch {
            presentError(error, action: "Create folder")
        }
    }

    func createFile() {
        if isCurrentSFTP {
            createSFTPFile()
            return
        }

        if isCurrentS3 {
            createS3File()
            return
        }

        let fileURL = uniqueURL(
            in: currentURL,
            baseName: "New File",
            pathExtension: "txt",
            copyStyle: false
        )

        guard fileManager.createFile(atPath: fileURL.path, contents: Data()) else {
            presentMessage("Create file failed: \(fileURL.path)")
            return
        }

        reload()
        selectOnly(fileURL)
        renameRequest = RenameRequest(url: fileURL, currentName: fileURL.lastPathComponent)
    }

    private func createSFTPFolder() {
        let folderURL = uniqueRemoteURL(
            in: currentURL,
            baseName: "New Folder",
            pathExtension: "",
            copyStyle: false
        )

        Task {
            do {
                try await SFTPClient.createDirectory(at: folderURL)
                reload()
                selectOnly(folderURL)
                renameRequest = RenameRequest(url: folderURL, currentName: folderURL.lastPathComponent)
            } catch {
                presentError(error, action: "Create SFTP folder")
            }
        }
    }

    private func createSFTPFile() {
        let fileURL = uniqueRemoteURL(
            in: currentURL,
            baseName: "New File",
            pathExtension: "txt",
            copyStyle: false
        )

        Task {
            do {
                try await SFTPClient.createFile(at: fileURL)
                reload()
                selectOnly(fileURL)
                renameRequest = RenameRequest(url: fileURL, currentName: fileURL.lastPathComponent)
            } catch {
                presentError(error, action: "Create SFTP file")
            }
        }
    }

    private func createS3Folder() {
        let folderURL = uniqueS3URL(
            in: currentURL,
            baseName: "New Folder",
            pathExtension: "",
            isDirectory: true,
            copyStyle: false
        )

        Task {
            do {
                try await S3Client.createDirectory(at: folderURL)
                reload()
                selectOnly(folderURL)
                renameRequest = RenameRequest(url: folderURL, currentName: folderURL.lastPathComponent)
            } catch {
                presentError(error, action: "Create S3 folder")
            }
        }
    }

    private func createS3File() {
        let fileURL = uniqueS3URL(
            in: currentURL,
            baseName: "New File",
            pathExtension: "txt",
            isDirectory: false,
            copyStyle: false
        )

        Task {
            do {
                try await S3Client.createFile(at: fileURL)
                reload()
                selectOnly(fileURL)
                renameRequest = RenameRequest(url: fileURL, currentName: fileURL.lastPathComponent)
            } catch {
                presentError(error, action: "Create S3 file")
            }
        }
    }

    func beginRename(_ item: FileItem) {
        renameRequest = RenameRequest(url: item.url, currentName: item.displayName)
    }

    func beginRenameSelected() {
        guard let item = selectedItems.first, selectedIDs.count == 1 else {
            return
        }

        beginRename(item)
    }

    func cancelRename() {
        renameRequest = nil
    }

    func rename(url: URL, to proposedName: String) {
        let newName = proposedName.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !newName.isEmpty else {
            presentMessage("Name cannot be empty.")
            return
        }

        let destinationURL = url.deletingLastPathComponent().appendingPathComponent(newName)

        guard destinationURL != url else {
            renameRequest = nil
            return
        }

        if SFTPClient.isSFTPURL(url) {
            renameSFTPItem(from: url, to: SFTPClient.childURL(named: newName, in: SFTPClient.parentURL(for: url)))
            return
        }

        if S3Client.isS3URL(url) {
            let isDirectory = items.first(where: { $0.url == url })?.isDirectory ?? S3Client.isDirectoryURL(url)
            let destinationURL = S3Client.childURL(
                named: newName,
                isDirectory: isDirectory,
                in: S3Client.parentURL(for: url)
            )
            renameS3Item(from: url, to: destinationURL)
            return
        }

        guard !fileManager.fileExists(atPath: destinationURL.path) else {
            presentMessage("An item named \"\(newName)\" already exists.")
            return
        }

        do {
            try fileManager.moveItem(at: url, to: destinationURL)
            renameRequest = nil
            reload()
            selectOnly(destinationURL)
        } catch {
            presentError(error, action: "Rename")
        }
    }

    private func renameSFTPItem(from sourceURL: URL, to destinationURL: URL) {
        guard !items.contains(where: { $0.url.lastPathComponent == destinationURL.lastPathComponent }) else {
            presentMessage("An item named \"\(destinationURL.lastPathComponent)\" already exists.")
            return
        }

        Task {
            do {
                try await SFTPClient.rename(from: sourceURL, to: destinationURL)
                renameRequest = nil
                reload()
                selectOnly(destinationURL)
            } catch {
                presentError(error, action: "Rename SFTP item")
            }
        }
    }

    private func renameS3Item(from sourceURL: URL, to destinationURL: URL) {
        guard !items.contains(where: { $0.url == destinationURL || $0.name == destinationURL.lastPathComponent }) else {
            presentMessage("An item named \"\(destinationURL.lastPathComponent)\" already exists.")
            return
        }

        Task {
            do {
                try await S3Client.rename(from: sourceURL, to: destinationURL)
                renameRequest = nil
                reload()
                selectOnly(destinationURL)
            } catch {
                presentError(error, action: "Rename S3 item")
            }
        }
    }

    func copySelection() {
        let urls = selectedURLs

        guard !urls.isEmpty else {
            return
        }

        pendingClipboardOperation = FileClipboardOperation(mode: .copy, urls: urls)
        writeURLsToPasteboard(urls)
    }

    func cutSelection() {
        let urls = selectedURLs

        guard !urls.isEmpty else {
            return
        }

        pendingClipboardOperation = FileClipboardOperation(mode: .cut, urls: urls)
        writeURLsToPasteboard(urls)
    }

    func handleFileCutShortcut() {
        if forwardTextAction(#selector(NSText.cut(_:))) {
            return
        }

        cutSelection()
    }

    func handleFileCopyShortcut() {
        if forwardTextAction(#selector(NSText.copy(_:))) {
            return
        }

        copySelection()
    }

    func handleFilePasteShortcut() {
        if forwardTextAction(#selector(NSText.paste(_:))) {
            return
        }

        pasteIntoCurrentFolder()
    }

    func handleSelectAllShortcut() {
        if forwardTextAction(#selector(NSResponder.selectAll(_:))) {
            return
        }

        selectedIDs = Set(displayedItems.map(\.url))
        selectionAnchorURL = firstSelectedURLInDisplayOrder()
    }

    func pasteIntoCurrentFolder() {
        paste(into: currentURL)
    }

    func paste(into destinationFolder: URL) {
        let operation = pendingClipboardOperation
            ?? FileClipboardOperation(mode: .copy, urls: readFileURLsFromPasteboard())

        guard !operation.urls.isEmpty else {
            return
        }

        if isRemoteURL(destinationFolder) || operation.urls.contains(where: isRemoteURL) {
            transfer(operation.urls, into: destinationFolder, mode: operation.mode)
            return
        }

        do {
            var pastedURLs: [URL] = []

            for sourceURL in operation.urls {
                let destinationURL = uniqueDestinationURL(for: sourceURL, in: destinationFolder)

                if operation.mode == .cut {
                    if sourceURL == destinationURL {
                        continue
                    }

                    try fileManager.moveItem(at: sourceURL, to: destinationURL)
                } else {
                    try fileManager.copyItem(at: sourceURL, to: destinationURL)
                }

                pastedURLs.append(destinationURL)
            }

            if operation.mode == .cut {
                pendingClipboardOperation = nil
            }

            reload()
            selectedIDs = Set(pastedURLs)
            selectionAnchorURL = pastedURLs.first
        } catch {
            presentError(error, action: operation.mode == .cut ? "Move" : "Copy")
        }
    }

    private func transfer(_ sourceURLs: [URL], into destinationFolder: URL, mode: FileClipboardMode) {
        let sftpSources = sourceURLs.filter(SFTPClient.isSFTPURL)
        let s3Sources = sourceURLs.filter(S3Client.isS3URL)
        let remoteSources = sftpSources + s3Sources
        let localSources = sourceURLs.filter { !isRemoteURL($0) }
        let destinationIsSFTP = SFTPClient.isSFTPURL(destinationFolder)
        let destinationIsS3 = S3Client.isS3URL(destinationFolder)

        Task {
            do {
                if destinationIsSFTP || destinationIsS3 {
                    guard remoteSources.isEmpty else {
                        presentMessage("Remote to remote copy is not supported yet.")
                        return
                    }

                    if destinationIsSFTP {
                        try await SFTPClient.upload(localURLs: localSources, to: destinationFolder)
                    } else {
                        try await S3Client.upload(localURLs: localSources, to: destinationFolder)
                    }

                    if mode == .cut {
                        try removeLocalItemsAfterRemoteMove(localSources)
                    }
                } else {
                    if !localSources.isEmpty {
                        try copyLocalItems(localSources, into: destinationFolder, mode: mode)
                    }

                    if !sftpSources.isEmpty {
                        try await SFTPClient.download(remoteURLs: sftpSources, to: destinationFolder)

                        if mode == .cut {
                            try await SFTPClient.remove(sftpSources)
                        }
                    }

                    if !s3Sources.isEmpty {
                        try await S3Client.download(remoteURLs: s3Sources, to: destinationFolder)

                        if mode == .cut {
                            try await S3Client.remove(s3Sources)
                        }
                    }
                }

                if mode == .cut {
                    pendingClipboardOperation = nil
                }

                reload()
            } catch {
                presentError(error, action: mode == .cut ? "Move" : "Copy")
            }
        }
    }

    private func copyLocalItems(_ sourceURLs: [URL], into destinationFolder: URL, mode: FileClipboardMode) throws {
        for sourceURL in sourceURLs {
            let destinationURL = uniqueDestinationURL(for: sourceURL, in: destinationFolder)

            if mode == .cut {
                if sourceURL != destinationURL {
                    try fileManager.moveItem(at: sourceURL, to: destinationURL)
                }
            } else {
                try fileManager.copyItem(at: sourceURL, to: destinationURL)
            }
        }
    }

    private func removeLocalItemsAfterRemoteMove(_ urls: [URL]) throws {
        for url in urls {
            var resultingURL: NSURL?
            try fileManager.trashItem(at: url, resultingItemURL: &resultingURL)
        }
    }

    func duplicate(_ item: FileItem) {
        if SFTPClient.isSFTPURL(item.url) {
            duplicateSFTPItem(item)
            return
        }

        if S3Client.isS3URL(item.url) {
            duplicateS3Item(item)
            return
        }

        do {
            let destinationURL = uniqueDestinationURL(for: item.url, in: item.url.deletingLastPathComponent())
            try fileManager.copyItem(at: item.url, to: destinationURL)
            reload()
            selectOnly(destinationURL)
        } catch {
            presentError(error, action: "Duplicate")
        }
    }

    private func duplicateSFTPItem(_ item: FileItem) {
        let baseName = item.isDirectory || item.url.pathExtension.isEmpty
            ? item.url.lastPathComponent
            : item.url.deletingPathExtension().lastPathComponent
        let pathExtension = item.isDirectory ? "" : item.url.pathExtension
        let destinationURL = uniqueRemoteURL(
            in: SFTPClient.parentURL(for: item.url),
            baseName: baseName,
            pathExtension: pathExtension,
            copyStyle: true
        )

        Task {
            do {
                try await SFTPClient.duplicate(from: item.url, to: destinationURL)
                reload()
                selectOnly(destinationURL)
            } catch {
                presentError(error, action: "Duplicate SFTP item")
            }
        }
    }

    private func duplicateS3Item(_ item: FileItem) {
        let baseName = item.isDirectory || item.url.pathExtension.isEmpty
            ? item.displayName
            : (item.displayName as NSString).deletingPathExtension
        let pathExtension = item.isDirectory ? "" : item.url.pathExtension
        let destinationURL = uniqueS3URL(
            in: S3Client.parentURL(for: item.url),
            baseName: baseName,
            pathExtension: pathExtension,
            isDirectory: item.isDirectory,
            copyStyle: true
        )

        Task {
            do {
                try await S3Client.duplicate(from: item.url, to: destinationURL)
                reload()
                selectOnly(destinationURL)
            } catch {
                presentError(error, action: "Duplicate S3 item")
            }
        }
    }

    func canCompress(_ item: FileItem) -> Bool {
        let items = contextualItems(for: item)
        return !items.isEmpty && items.allSatisfy { !isRemoteURL($0.url) }
    }

    func canExtract(_ item: FileItem) -> Bool {
        let items = contextualItems(for: item)
        return !items.isEmpty && items.allSatisfy {
            !$0.isDirectory && !isRemoteURL($0.url) && ArchiveFormat.format(for: $0.url) != nil
        }
    }

    func compress(_ item: FileItem, as format: ArchiveFormat) {
        let items = contextualItems(for: item)
        let urls = items.map(\.url)

        guard !urls.isEmpty,
              urls.allSatisfy({ !isRemoteURL($0) }),
              let parentDirectory = commonParentDirectory(for: urls) else {
            return
        }

        let baseName = archiveBaseName(for: items)
        let destinationURL = uniqueArchiveURL(
            in: parentDirectory,
            baseName: baseName,
            fileExtension: format.fileExtension
        )
        let sourceNames = urls.map(\.lastPathComponent)

        Task {
            do {
                try await ArchiveClient.createArchive(
                    format: format,
                    sourceNames: sourceNames,
                    parentDirectory: parentDirectory,
                    destinationURL: destinationURL
                )
                reload()
                selectOnly(destinationURL)
            } catch {
                presentError(error, action: "Compress")
            }
        }
    }

    func extract(_ item: FileItem) {
        let items = contextualItems(for: item)

        guard canExtract(item) else {
            return
        }

        Task {
            do {
                var extractedURLs: [URL] = []

                for item in items {
                    guard let format = ArchiveFormat.format(for: item.url) else {
                        continue
                    }

                    let parentDirectory = item.url.deletingLastPathComponent()
                    let destinationDirectory = uniqueURL(
                        in: parentDirectory,
                        baseName: extractionBaseName(for: item.url),
                        pathExtension: "",
                        copyStyle: false
                    )

                    try await ArchiveClient.extractArchive(
                        format: format,
                        archiveURL: item.url,
                        destinationDirectory: destinationDirectory
                    )
                    extractedURLs.append(destinationDirectory)
                }

                reload()
                selectedIDs = Set(extractedURLs)
                selectionAnchorURL = extractedURLs.first
            } catch {
                presentError(error, action: "Extract")
            }
        }
    }

    private func contextualItems(for item: FileItem) -> [FileItem] {
        if selectedIDs.contains(item.url), !selectedItems.isEmpty {
            return selectedItems
        }

        return [item]
    }

    private func commonParentDirectory(for urls: [URL]) -> URL? {
        guard let firstURL = urls.first else {
            return nil
        }

        let firstParent = firstURL.deletingLastPathComponent().standardizedFileURL

        guard urls.allSatisfy({ $0.deletingLastPathComponent().standardizedFileURL == firstParent }) else {
            return nil
        }

        return firstParent
    }

    private func archiveBaseName(for items: [FileItem]) -> String {
        guard items.count == 1, let item = items.first else {
            return L10n.string("Archive")
        }

        return item.displayName
    }

    private func uniqueArchiveURL(in folder: URL, baseName: String, fileExtension: String) -> URL {
        func makeURL(name: String) -> URL {
            folder.appendingPathComponent(name).appendingPathExtension(fileExtension)
        }

        let firstURL = makeURL(name: baseName)

        guard !fileManager.fileExists(atPath: firstURL.path) else {
            var index = 2

            while true {
                let candidateURL = makeURL(name: "\(baseName) \(index)")

                if !fileManager.fileExists(atPath: candidateURL.path) {
                    return candidateURL
                }

                index += 1
            }
        }

        return firstURL
    }

    private func extractionBaseName(for archiveURL: URL) -> String {
        let filename = archiveURL.lastPathComponent
        let lowercasedFilename = filename.lowercased()
        let knownExtensions = ArchiveFormat.allCases
            .flatMap(\.knownExtensions)
            .sorted { $0.count > $1.count }

        for pathExtension in knownExtensions where lowercasedFilename.hasSuffix(".\(pathExtension)") {
            let dropCount = pathExtension.count + 1
            let baseName = String(filename.dropLast(dropCount))

            if !baseName.isEmpty {
                return baseName
            }
        }

        return archiveURL.deletingPathExtension().lastPathComponent.nilIfEmpty
            ?? L10n.string("Extracted Archive")
    }

    func trashSelection() {
        let urls = selectedURLs

        guard !urls.isEmpty else {
            return
        }

        if urls.contains(where: isRemoteURL) {
            deleteRemoteItems(urls)
            return
        }

        do {
            for url in urls {
                var resultingURL: NSURL?
                try fileManager.trashItem(at: url, resultingItemURL: &resultingURL)
            }

            reload()
        } catch {
            presentError(error, action: "Move to Trash")
        }
    }

    private func deleteRemoteItems(_ urls: [URL]) {
        let localURLs = urls.filter { !isRemoteURL($0) }
        let sftpURLs = urls.filter(SFTPClient.isSFTPURL)
        let s3URLs = urls.filter(S3Client.isS3URL)

        Task {
            do {
                if !localURLs.isEmpty {
                    for url in localURLs {
                        var resultingURL: NSURL?
                        try fileManager.trashItem(at: url, resultingItemURL: &resultingURL)
                    }
                }

                if !sftpURLs.isEmpty {
                    try await SFTPClient.remove(sftpURLs)
                }

                if !s3URLs.isEmpty {
                    try await S3Client.remove(s3URLs)
                }

                reload()
            } catch {
                presentError(error, action: "Delete remote item")
            }
        }
    }

    func copyPath(_ item: FileItem) {
        copyPath(item.url)
    }

    func copyPath(_ url: URL) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(displayString(for: url), forType: .string)
    }

    func revealInFinder(_ item: FileItem) {
        revealInFinder(item.url)
    }

    func revealInFinder(_ url: URL) {
        guard !isRemoteURL(url) else {
            presentMessage("Reveal in Finder is not available for remote locations.")
            return
        }

        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    func addFavoriteFolders(from providers: [NSItemProvider]) -> Bool {
        var acceptedDrop = false
        let supportedTypeIdentifiers = [
            UTType.fileURL.identifier,
            UTType.url.identifier,
            UTType.plainText.identifier
        ]

        for provider in providers {
            guard let typeIdentifier = supportedTypeIdentifiers.first(where: {
                provider.hasItemConformingToTypeIdentifier($0)
            }) else {
                continue
            }

            acceptedDrop = true
            provider.loadItem(forTypeIdentifier: typeIdentifier, options: nil) { [weak self] item, error in
                let path = Self.filePath(fromDroppedItem: item)
                let errorMessage = error?.localizedDescription

                Task { @MainActor in
                    self?.addFavoriteFolderFromDrop(path: path, errorMessage: errorMessage)
                }
            }
        }

        return acceptedDrop
    }

    func addFavoriteFolder(_ url: URL) {
        let folderURL = url.standardizedFileURL

        guard Self.isDirectory(folderURL, fileManager: fileManager) else {
            presentMessage("Only folders can be added to Favorites.")
            return
        }

        let path = folderURL.path
        let defaultFavoritePaths = Set(Self.defaultFavoriteURLs().map { $0.standardizedFileURL.path })
        let userFavoritePaths = Set(userFavoriteFolders.map { $0.standardizedFileURL.path })

        guard !defaultFavoritePaths.contains(path), !userFavoritePaths.contains(path) else {
            return
        }

        userFavoriteFolders.append(folderURL)
        saveUserFavoriteFolders()
        refreshSidebarLocations()
    }

    func removeFavorite(_ location: SidebarLocation) {
        guard location.canRemoveFromFavorites else {
            return
        }

        let removedPath = location.url.standardizedFileURL.path
        userFavoriteFolders.removeAll { $0.standardizedFileURL.path == removedPath }
        saveUserFavoriteFolders()
        refreshSidebarLocations()
    }

    func disconnect(_ location: SidebarLocation) {
        guard location.canDisconnect else {
            return
        }

        let url = location.url
        if let connectionURL = location.connectionURL,
           let kind = remoteConnectionKind(for: connectionURL.absoluteString),
           kind == .sftp || kind == .s3 {
            removeServerConnection(kind: kind, url: connectionURL)
            refreshSidebarLocations()

            if (kind == .sftp && SFTPClient.isSFTPURL(currentURL)
                || kind == .s3 && S3Client.isS3URL(currentURL)),
               currentURL.host(percentEncoded: false) == connectionURL.host(percentEncoded: false) {
                navigate(to: fileManager.homeDirectoryForCurrentUser)
            }

            return
        }

        if location.isUnavailable, let connectionURL = location.connectionURL {
            let kind = remoteConnectionKind(for: connectionURL.absoluteString) ?? .smb
            removeServerConnection(kind: kind, url: connectionURL)
            refreshSidebarLocations()
            return
        }

        do {
            try NSWorkspace.shared.unmountAndEjectDevice(at: url)

            if let connectionURL = location.connectionURL {
                let kind = remoteConnectionKind(for: connectionURL.absoluteString) ?? .smb
                removeServerConnection(kind: kind, url: connectionURL)
            }

            refreshSidebarLocations()

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                self?.refreshSidebarLocations()
            }
        } catch {
            presentError(error, action: "Disconnect")
        }
    }

    func shareSelectionViaAirDrop() {
        let urls = selectedURLs

        guard !urls.isEmpty else {
            return
        }

        guard !urls.contains(where: isRemoteURL) else {
            presentMessage("AirDrop is not available for remote items.")
            return
        }

        guard let service = NSSharingService(named: .sendViaAirDrop) else {
            presentMessage("AirDrop is not available.")
            return
        }

        service.perform(withItems: urls)
    }

    func openInTerminal(_ url: URL) {
        openDirectory(url, in: .terminal)
    }

    func openIniTerm(_ url: URL) {
        openDirectory(url, in: .iTerm)
    }

    func showExternalToolsSettings() {
        isExternalToolsSettingsPresented = true
    }

    func showLauncherFoldersSettings() {
        isLauncherFoldersSettingsPresented = true
    }

    func saveExternalTools(_ tools: [ExternalTool]) {
        externalTools = tools.map(\.normalized)
        saveExternalTools()
        isExternalToolsSettingsPresented = false
    }

    func saveLauncherFolderShortcuts(_ shortcuts: [LauncherFolderShortcut]) {
        launcherFolderShortcuts = shortcuts.map(\.normalized)
        LauncherFolderShortcutStore.save(launcherFolderShortcuts)
        isLauncherFoldersSettingsPresented = false
    }

    func resetExternalTools() {
        externalTools = ExternalTool.defaultTools
        saveExternalTools()
    }

    func openExternalTool(_ tool: ExternalTool) {
        let normalizedTool = tool.normalized

        switch normalizedTool.kind {
        case .terminal:
            guard let targetURL = targetURL(for: normalizedTool) else {
                presentMessage("Select one folder to open in \(normalizedTool.title).")
                return
            }

            openDirectory(targetURL, in: .terminal)
        case .iTerm:
            guard let targetURL = targetURL(for: normalizedTool) else {
                presentMessage("Select one folder to open in \(normalizedTool.title).")
                return
            }

            openDirectory(targetURL, in: .iTerm)
        case .application:
            openFolderWithApplicationTool(normalizedTool)
        }
    }

    func canOpenExternalTool(_ tool: ExternalTool) -> Bool {
        let normalizedTool = tool.normalized

        switch normalizedTool.kind {
        case .terminal:
            guard let targetURL = targetURL(for: normalizedTool) else {
                return false
            }

            return !S3Client.isS3URL(targetURL)
        case .iTerm:
            guard let targetURL = targetURL(for: normalizedTool) else {
                return false
            }

            return isITermAvailable && !S3Client.isS3URL(targetURL)
        case .application:
            guard let targetURL = targetURL(for: normalizedTool),
                  !isRemoteURL(targetURL) else {
                return false
            }

            return applicationURL(for: normalizedTool) != nil
        }
    }

    func applicationIcon(for tool: ExternalTool) -> NSImage? {
        guard tool.iconMode == .applicationIcon,
              let applicationURL = applicationURL(for: tool.normalized) else {
            return nil
        }

        return NSWorkspace.shared.icon(forFile: applicationURL.path)
    }

    func refreshSidebarLocations() {
        sidebarSections = Self.makeSidebarSections(
            userFavoriteFolders: userFavoriteFolders,
            serverConnections: serverConnections,
            locationOrderIDs: sidebarLocationOrderIDs
        )
    }

    func reloadLocations() {
        refreshSidebarLocations()
        reconnectSavedServers()
    }

    func promptConnectToServer() {
        connectProtocol = .smb
        connectServerAddress = connectProtocol.defaultAddress
        connectServerDisplayName = ""
        connectAWSProfile = ""
        isConnectServerDialogPresented = true
    }

    func commitConnectServerDialog() {
        let address = connectServerAddress
        let displayName = connectServerDisplayName.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        let awsProfile = connectProtocol == .s3
            ? connectAWSProfile.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
            : nil
        isConnectServerDialogPresented = false

        connectToServer(kind: connectProtocol, address: address, displayName: displayName, awsProfile: awsProfile)
    }

    func cancelConnectServerDialog() {
        isConnectServerDialogPresented = false
    }

    func moveSidebarLocation(sourceID: String, over targetID: String) {
        guard sourceID != targetID,
              let currentIDs = currentLocationIDs(),
              let sourceIndex = currentIDs.firstIndex(of: sourceID),
              let targetIndex = currentIDs.firstIndex(of: targetID) else {
            return
        }

        var nextIDs = currentIDs
        let movedID = nextIDs.remove(at: sourceIndex)

        guard let adjustedTargetIndex = nextIDs.firstIndex(of: targetID) else {
            return
        }

        let insertionIndex = sourceIndex < targetIndex
            ? min(adjustedTargetIndex + 1, nextIDs.count)
            : adjustedTargetIndex

        nextIDs.insert(movedID, at: insertionIndex)
        persistSidebarLocationOrder(nextIDs)
    }

    func moveSidebarLocationToEnd(sourceID: String) {
        guard let currentIDs = currentLocationIDs(),
              currentIDs.contains(sourceID),
              currentIDs.last != sourceID else {
            return
        }

        var nextIDs = currentIDs
        nextIDs.removeAll { $0 == sourceID }
        nextIDs.append(sourceID)
        persistSidebarLocationOrder(nextIDs)
    }

    func refreshAWSProfiles() {
        Task {
            do {
                let profiles = try await S3Client.availableProfiles()

                await MainActor.run {
                    self.awsProfiles = profiles

                    if !self.connectAWSProfile.isEmpty,
                       !profiles.contains(self.connectAWSProfile) {
                        self.connectAWSProfile = ""
                    }
                }
            } catch {
                await MainActor.run {
                    self.awsProfiles = []
                }
            }
        }
    }

    func connectToServer(
        kind selectedKind: RemoteConnectionKind,
        address: String,
        displayName: String?,
        awsProfile: String? = nil
    ) {
        let trimmedAddress = address.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmedAddress.isEmpty else {
            return
        }

        let normalizedAddress = normalizedRemoteAddress(trimmedAddress, kind: selectedKind)
        let kind = remoteConnectionKind(for: normalizedAddress) ?? selectedKind

        guard let url = URL(string: normalizedAddress) else {
            presentMessage("Invalid server address: \(trimmedAddress)")
            return
        }

        let profile = kind == .s3 ? awsProfile : nil

        mountServerConnection(
            kind: kind,
            url: url,
            displayName: displayName,
            awsProfile: profile,
            silentFailure: false
        )
    }

    func clearError() {
        errorMessage = nil
    }

    func setAppLanguageMode(_ mode: AppLanguageMode) {
        L10n.setLanguageMode(mode)
        appLanguageMode = mode
        refreshSidebarLocations()
        AppMenuLocalizer.apply()

        DispatchQueue.main.async {
            AppMenuLocalizer.apply()
        }
    }

    func setAppAppearanceMode(_ mode: AppAppearanceMode) {
        AppAppearance.setMode(mode)
        appAppearanceMode = mode
    }

    private static func makeSidebarSections(
        userFavoriteFolders: [URL],
        serverConnections: [ServerConnection],
        locationOrderIDs: [String]
    ) -> [SidebarSection] {
        let fileManager = FileManager.default
        let homeURL = fileManager.homeDirectoryForCurrentUser
        let defaultFavorites = [
            SidebarLocation(title: "Home", systemImageName: "house", url: homeURL),
            SidebarLocation(title: "Desktop", systemImageName: "desktopcomputer", url: homeURL.appendingPathComponent("Desktop")),
            SidebarLocation(title: "Documents", systemImageName: "doc.text", url: homeURL.appendingPathComponent("Documents")),
            SidebarLocation(title: "Downloads", systemImageName: "arrow.down.circle", url: homeURL.appendingPathComponent("Downloads")),
            SidebarLocation(title: "Applications", systemImageName: "app", url: URL(fileURLWithPath: "/Applications", isDirectory: true))
        ].filter { fileManager.fileExists(atPath: $0.url.path) }

        let customFavorites = userFavoriteFolders
            .filter { fileManager.fileExists(atPath: $0.path) }
            .map { url in
                SidebarLocation(
                    title: fileManager.displayName(atPath: url.path),
                    systemImageName: "folder",
                    url: url,
                    canRemoveFromFavorites: true
                )
            }

        let favorites = deduplicatedPreservingOrder(defaultFavorites + customFavorites)

        let locations = finderStyleLocations(
            homeURL: homeURL,
            serverConnections: serverConnections,
            locationOrderIDs: locationOrderIDs
        )

        return [
            SidebarSection(title: "Favorites", locations: favorites),
            SidebarSection(title: "Locations", locations: locations)
        ].filter { !$0.locations.isEmpty }
    }

    private static func defaultFavoriteURLs() -> [URL] {
        let homeURL = FileManager.default.homeDirectoryForCurrentUser

        return [
            homeURL,
            homeURL.appendingPathComponent("Desktop"),
            homeURL.appendingPathComponent("Documents"),
            homeURL.appendingPathComponent("Downloads"),
            URL(fileURLWithPath: "/Applications", isDirectory: true)
        ]
    }

    private static func finderStyleLocations(
        homeURL: URL,
        serverConnections: [ServerConnection],
        locationOrderIDs: [String]
    ) -> [SidebarLocation] {
        let locations = deduplicatedPreservingOrder(
            computerLocations()
                + connectedServerLocations(serverConnections)
                + mountedVolumeLocations()
                + cloudStorageLocations(homeURL: homeURL)
        )

        return orderedLocations(locations, orderIDs: locationOrderIDs)
    }

    private static func connectedServerLocations(_ connections: [ServerConnection]) -> [SidebarLocation] {
        connections.compactMap { connection in
            guard let connectionURL = URL(string: connection.urlString) else {
                return nil
            }
            let kind = connection.kind

            if kind == .sftp || kind == .s3 {
                return SidebarLocation(
                    title: remoteConnectionTitle(
                        for: connection,
                        fallbackName: serverConnectionTitle(for: connectionURL),
                        isUnavailable: connection.isUnavailable
                    ),
                    systemImageName: connection.isUnavailable ? "exclamationmark.triangle" : kind.systemImageName,
                    url: connectionURL,
                    connectionURL: connectionURL,
                    isUnavailable: connection.isUnavailable,
                    canDisconnect: true
                )
            }

            if let mountPath = connection.mountPath,
               FileManager.default.fileExists(atPath: mountPath) {
                let mountURL = URL(fileURLWithPath: mountPath, isDirectory: true)
                let fallbackTitle = FileManager.default.displayName(atPath: mountURL.path).nilIfEmpty
                    ?? mountURL.lastPathComponent

                return SidebarLocation(
                    title: remoteConnectionTitle(for: connection, fallbackName: fallbackTitle, isUnavailable: false),
                    systemImageName: kind.systemImageName,
                    url: mountURL,
                    connectionURL: connectionURL,
                    canDisconnect: true
                )
            }

            return SidebarLocation(
                title: remoteConnectionTitle(
                    for: connection,
                    fallbackName: serverConnectionTitle(for: connectionURL),
                    isUnavailable: true
                ),
                systemImageName: "exclamationmark.triangle",
                url: unavailableServerPlaceholderURL(for: connectionURL, kind: kind),
                connectionURL: connectionURL,
                isUnavailable: true,
                canDisconnect: true
            )
        }
    }

    private static func remoteConnectionTitle(
        kind: RemoteConnectionKind,
        name: String,
        isUnavailable: Bool
    ) -> String {
        let title = "\(L10n.string(kind.displayName)) - \(name)"
        return isUnavailable ? L10n.format("location.unavailable", title) : title
    }

    private static func remoteConnectionTitle(
        for connection: ServerConnection,
        fallbackName: String,
        isUnavailable: Bool
    ) -> String {
        let trimmedDisplayName = connection.displayName?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmpty

        guard let trimmedDisplayName else {
            return remoteConnectionTitle(
                kind: connection.kind,
                name: fallbackName,
                isUnavailable: isUnavailable
            )
        }

        return isUnavailable ? L10n.format("location.unavailable", trimmedDisplayName) : trimmedDisplayName
    }

    private func normalizedRemoteAddress(
        _ address: String,
        kind: RemoteConnectionKind
    ) -> String {
        if address.contains("://") {
            return address
        }

        return "\(kind.defaultAddress)\(address)"
    }

    private func remoteConnectionKind(for address: String) -> RemoteConnectionKind? {
        guard let scheme = URL(string: address)?.scheme?.lowercased() else {
            return nil
        }

        switch scheme {
        case "smb", "cifs":
            return .smb
        case "sftp":
            return .sftp
        case "ftp", "ftps":
            return .ftp
        case "s3":
            return .s3
        default:
            return nil
        }
    }

    private static func serverConnectionTitle(for url: URL) -> String {
        if let host = url.host, !host.isEmpty {
            let path = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            return path.isEmpty ? host : "\(host)/\(path)"
        }

        return url.absoluteString
    }

    private static func unavailableServerPlaceholderURL(
        for url: URL,
        kind: RemoteConnectionKind
    ) -> URL {
        let title = "\(kind.displayName)-\(serverConnectionTitle(for: url))"
            .replacingOccurrences(of: "/", with: "-")
            .nilIfEmpty
            ?? "Unavailable Server"

        return URL(fileURLWithPath: "/Volumes/\(title)", isDirectory: true)
    }

    private func reconnectSavedServers() {
        for connection in serverConnections {
            guard let url = URL(string: connection.urlString),
                  !isServerConnectionAvailable(connection) else {
                continue
            }

            mountServerConnection(
                kind: connection.kind,
                url: url,
                displayName: connection.displayName,
                awsProfile: connection.awsProfile,
                silentFailure: true
            )
        }
    }

    private func mountServerConnection(
        kind: RemoteConnectionKind,
        url: URL,
        displayName: String?,
        awsProfile: String? = nil,
        silentFailure: Bool
    ) {
        let connectionURL = kind == .s3
            ? S3Client.url(bySettingProfile: awsProfile ?? S3Client.profile(for: url), on: url)
            : url

        if kind == .sftp {
            connectSFTPServer(url: connectionURL, displayName: displayName, silentFailure: silentFailure)
            return
        }

        if kind == .s3 {
            connectS3Server(
                url: connectionURL,
                replacing: url,
                displayName: displayName,
                awsProfile: awsProfile ?? S3Client.profile(for: connectionURL),
                silentFailure: silentFailure
            )
            return
        }

        let connectionID = serverConnectionID(kind: kind, urlString: connectionURL.absoluteString)

        guard reconnectingServerIDs.insert(connectionID).inserted else {
            return
        }

        guard kind.canMountThroughSystem else {
            reconnectingServerIDs.remove(connectionID)
            upsertServerConnection(
                kind: kind,
                url: connectionURL,
                displayName: displayName,
                mountURL: nil,
                isUnavailable: true
            )
            refreshSidebarLocations()
            return
        }

        Task {
            let result = await mountNetworkURL(url)
            reconnectingServerIDs.remove(connectionID)

            if result.status == 0, let mountURL = result.mountURLs.first {
                upsertServerConnection(
                    kind: kind,
                    url: connectionURL,
                    displayName: displayName,
                    mountURL: mountURL,
                    isUnavailable: false
                )
                refreshSidebarLocations()

                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                    self?.refreshSidebarLocations()
                }
                return
            }

            if hasServerConnection(kind: kind, url: connectionURL) {
                upsertServerConnection(
                    kind: kind,
                    url: connectionURL,
                    displayName: displayName,
                    mountURL: nil,
                    isUnavailable: true
                )
                refreshSidebarLocations()
            }

            if !silentFailure, result.status != -128 {
                presentMessage("Could not connect server: \(connectionURL.absoluteString) (status \(result.status))")
            }
        }
    }

    private func connectSFTPServer(url: URL, displayName: String?, silentFailure: Bool) {
        let connectionID = serverConnectionID(kind: .sftp, urlString: url.absoluteString)

        guard reconnectingServerIDs.insert(connectionID).inserted else {
            return
        }

        Task {
            do {
                let resolvedURL = try await SFTPClient.resolvedDirectoryURL(for: url)
                reconnectingServerIDs.remove(connectionID)
                upsertServerConnection(
                    kind: .sftp,
                    url: resolvedURL,
                    replacing: url,
                    displayName: displayName,
                    mountURL: nil,
                    isUnavailable: false
                )
                refreshSidebarLocations()

                if !silentFailure {
                    navigate(to: resolvedURL)
                }
            } catch {
                reconnectingServerIDs.remove(connectionID)
                upsertServerConnection(
                    kind: .sftp,
                    url: url,
                    displayName: displayName,
                    mountURL: nil,
                    isUnavailable: true
                )
                refreshSidebarLocations()

                if !silentFailure {
                    presentError(error, action: "Connect SFTP")
                }
            }
        }
    }

    private func connectS3Server(
        url: URL,
        replacing oldURL: URL? = nil,
        displayName: String?,
        awsProfile: String?,
        silentFailure: Bool
    ) {
        let connectionID = serverConnectionID(kind: .s3, urlString: url.absoluteString)

        guard reconnectingServerIDs.insert(connectionID).inserted else {
            return
        }

        Task {
            do {
                let result = try await S3Client.listDirectory(at: url, showHiddenFiles: showHiddenFiles)
                reconnectingServerIDs.remove(connectionID)
                upsertServerConnection(
                    kind: .s3,
                    url: result.url,
                    replacing: oldURL ?? url,
                    displayName: displayName,
                    awsProfile: awsProfile,
                    mountURL: nil,
                    isUnavailable: false
                )
                refreshSidebarLocations()

                if !silentFailure {
                    navigate(to: result.url)
                }
            } catch {
                reconnectingServerIDs.remove(connectionID)
                upsertServerConnection(
                    kind: .s3,
                    url: url,
                    replacing: oldURL,
                    displayName: displayName,
                    awsProfile: awsProfile,
                    mountURL: nil,
                    isUnavailable: true
                )
                refreshSidebarLocations()

                if !silentFailure {
                    presentError(error, action: "Connect S3")
                }
            }
        }
    }

    private func isServerConnectionAvailable(_ connection: ServerConnection) -> Bool {
        if connection.kind == .sftp || connection.kind == .s3 {
            return !connection.isUnavailable
        }

        guard let mountPath = connection.mountPath else {
            return false
        }

        return fileManager.fileExists(atPath: mountPath)
    }

    private func hasServerConnection(kind: RemoteConnectionKind, url: URL) -> Bool {
        let id = serverConnectionID(kind: kind, urlString: url.absoluteString)
        return serverConnections.contains {
            serverConnectionID(kind: $0.kind, urlString: $0.urlString) == id
        }
    }

    private func serverConnection(kind: RemoteConnectionKind, url: URL) -> ServerConnection? {
        let id = serverConnectionID(kind: kind, urlString: url.absoluteString)
        return serverConnections.first {
            serverConnectionID(kind: $0.kind, urlString: $0.urlString) == id
        }
    }

    private func upsertServerConnection(
        kind: RemoteConnectionKind,
        url: URL,
        replacing oldURL: URL? = nil,
        displayName: String?,
        awsProfile: String? = nil,
        mountURL: URL?,
        isUnavailable: Bool
    ) {
        let urlString = url.absoluteString
        let mountPath = mountURL?.standardizedFileURL.path
        let normalizedAWSProfile = kind == .s3
            ? (awsProfile ?? S3Client.profile(for: url))
            : nil
        let id = serverConnectionID(kind: kind, urlString: urlString)

        if let oldURL, oldURL.absoluteString != urlString {
            let oldID = serverConnectionID(kind: kind, urlString: oldURL.absoluteString)
            serverConnections.removeAll {
                serverConnectionID(kind: $0.kind, urlString: $0.urlString) == oldID
            }
        }

        if let index = serverConnections.firstIndex(where: {
            serverConnectionID(kind: $0.kind, urlString: $0.urlString) == id
        }) {
            serverConnections[index].kind = kind
            if let displayName {
                serverConnections[index].displayName = displayName
            }
            serverConnections[index].awsProfile = normalizedAWSProfile
            serverConnections[index].mountPath = mountPath
            serverConnections[index].isUnavailable = isUnavailable
        } else {
            serverConnections.append(
                ServerConnection(
                    kind: kind,
                    urlString: urlString,
                    displayName: displayName,
                    awsProfile: normalizedAWSProfile,
                    mountPath: mountPath,
                    isUnavailable: isUnavailable
                )
            )
        }

        saveServerConnections()
    }

    private func markServerConnectionAvailable(_ url: URL) {
        let kind: RemoteConnectionKind

        if SFTPClient.isSFTPURL(url) {
            kind = .sftp
        } else if S3Client.isS3URL(url) {
            kind = .s3
        } else {
            return
        }

        guard
              let index = serverConnections.firstIndex(where: {
                  $0.kind == kind && $0.urlString == url.absoluteString
              }) else {
            return
        }

        serverConnections[index].isUnavailable = false
        saveServerConnections()
        refreshSidebarLocations()
    }

    private func markServerConnectionUnavailable(_ url: URL) {
        let kind: RemoteConnectionKind

        if SFTPClient.isSFTPURL(url) {
            kind = .sftp
        } else if S3Client.isS3URL(url) {
            kind = .s3
        } else {
            return
        }

        guard
              let index = serverConnections.firstIndex(where: {
                  $0.kind == kind && $0.urlString == url.absoluteString
              }) else {
            return
        }

        serverConnections[index].isUnavailable = true
        saveServerConnections()
        refreshSidebarLocations()
    }

    private func removeServerConnection(kind: RemoteConnectionKind, url: URL) {
        let id = serverConnectionID(kind: kind, urlString: url.absoluteString)
        serverConnections.removeAll {
            serverConnectionID(kind: $0.kind, urlString: $0.urlString) == id
        }
        saveServerConnections()
    }

    private func serverConnectionID(kind: RemoteConnectionKind, urlString: String) -> String {
        "\(kind.rawValue):\(urlString)"
    }

    private static func computerLocations() -> [SidebarLocation] {
        let volumesURL = URL(fileURLWithPath: "/Volumes", isDirectory: true)

        guard FileManager.default.fileExists(atPath: volumesURL.path) else {
            return []
        }

        let title = Host.current().localizedName?
            .replacingOccurrences(of: ".local", with: "")
            .nilIfEmpty
            ?? "This Mac"

        return [
            SidebarLocation(
                title: title,
                systemImageName: "desktopcomputer",
                url: volumesURL
            )
        ]
    }

    private static func cloudStorageLocations(homeURL: URL) -> [SidebarLocation] {
        let fileManager = FileManager.default
        var urls: [URL] = []

        let cloudStorageURL = homeURL
            .appendingPathComponent("Library")
            .appendingPathComponent("CloudStorage")

        let cloudStorageContents = (try? fileManager.contentsOfDirectory(
            at: cloudStorageURL,
            includingPropertiesForKeys: [.isDirectoryKey, .localizedNameKey],
            options: [.skipsHiddenFiles]
        )) ?? []

        let cloudStorageDirectories = cloudStorageContents.filter { url in
            isUsableSidebarDirectory(url, fileManager: fileManager)
                && shouldShowCloudStorageLocation(url)
        }

        urls.append(contentsOf: cloudStorageDirectories)

        let shouldUseLegacyHomeCloudFolders = cloudStorageDirectories.isEmpty

        if shouldUseLegacyHomeCloudFolders, let homeContents = try? fileManager.contentsOfDirectory(
            at: homeURL,
            includingPropertiesForKeys: [
                .isDirectoryKey,
                .isSymbolicLinkKey,
                .isAliasFileKey,
                .isReadableKey,
                .localizedNameKey
            ],
            options: [.skipsHiddenFiles]
        ) {
            urls.append(
                contentsOf: homeContents.filter { url in
                    let name = url.lastPathComponent.lowercased()
                    return isUsableSidebarDirectory(url, fileManager: fileManager)
                        && shouldShowCloudStorageLocation(url)
                        && (name.hasPrefix("google drive") || name.hasPrefix("googledrive") || name.hasPrefix("onedrive"))
                }
            )
        }

        return deduplicatedPreservingOrder(urls.map { url in
            SidebarLocation(
                title: cloudStorageTitle(for: url),
                systemImageName: cloudStorageIconName(for: url),
                url: url
            )
        })
        .sorted { left, right in
            let leftRank = cloudStorageSortRank(left.url)
            let rightRank = cloudStorageSortRank(right.url)

            if leftRank != rightRank {
                return leftRank < rightRank
            }

            return left.title.localizedStandardCompare(right.title) == .orderedAscending
        }
    }

    private static func mountedVolumeLocations() -> [SidebarLocation] {
        let keys: [URLResourceKey] = [
            .volumeNameKey,
            .volumeIsLocalKey,
            .volumeIsInternalKey,
            .volumeIsRemovableKey
        ]

        let volumeURLs = FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: keys,
            options: [.skipHiddenVolumes]
        ) ?? []

        let locations = volumeURLs.compactMap { url -> SidebarLocation? in
            let values = try? url.resourceValues(forKeys: Set(keys))
            let title = values?.volumeName
                ?? FileManager.default.displayName(atPath: url.path)
                .nilIfEmpty
                ?? url.lastPathComponent
            let isLocal = values?.volumeIsLocal ?? true
            let isInternal = values?.volumeIsInternal ?? false
            let isRemovable = values?.volumeIsRemovable ?? false
            let iconName: String

            if !isLocal {
                iconName = "network"
            } else if isRemovable {
                iconName = "externaldrive"
            } else if isInternal {
                iconName = "internaldrive"
            } else {
                iconName = "externaldrive.connected.to.line.below"
            }

            return SidebarLocation(
                title: title,
                systemImageName: iconName,
                url: url,
                canDisconnect: !isLocal || isRemovable
            )
        }

        return deduplicatedPreservingOrder(locations)
            .sorted { left, right in
                let leftRank = volumeSortRank(left.url)
                let rightRank = volumeSortRank(right.url)

                if leftRank != rightRank {
                    return leftRank < rightRank
                }

                return left.title.localizedStandardCompare(right.title) == .orderedAscending
            }
    }

    private static func cloudStorageTitle(for url: URL) -> String {
        let rawName = url.lastPathComponent
        let lowercasedName = rawName.lowercased()

        if lowercasedName.hasPrefix("googledrive") || lowercasedName.hasPrefix("google drive") {
            return cleanedCloudName(rawName, provider: "Google Drive", rawPrefixes: ["GoogleDrive", "Google Drive"])
        }

        if lowercasedName.hasPrefix("onedrive-共有ライブラリ")
            || lowercasedName.hasPrefix("onedrive-共有ライブラリ") {
            return cleanedCloudName(
                rawName,
                provider: "SharePoint",
                rawPrefixes: ["OneDrive-共有ライブラリ", "OneDrive-共有ライブラリ"]
            )
        }

        if lowercasedName.hasPrefix("onedrive") {
            return cleanedCloudName(rawName, provider: "OneDrive", rawPrefixes: ["OneDrive"])
        }

        if lowercasedName.contains("sharepoint") {
            return cleanedCloudName(rawName, provider: "SharePoint", rawPrefixes: ["SharePoint"])
        }

        return FileManager.default.displayName(atPath: url.path)
    }

    private static func cleanedCloudName(
        _ rawName: String,
        provider: String,
        rawPrefixes: [String]
    ) -> String {
        let separators = ["-", " "]

        for rawPrefix in rawPrefixes {
            for separator in separators {
                let prefix = "\(rawPrefix)\(separator)"

                if rawName.hasPrefix(prefix) {
                    let suffix = rawName
                        .dropFirst(prefix.count)
                        .trimmingCharacters(in: .whitespacesAndNewlines)

                    return suffix.isEmpty ? provider : "\(provider) - \(suffix)"
                }
            }
        }

        if rawPrefixes.contains(rawName) || rawName == provider {
            return provider
        }

        return rawName
    }

    private static func cloudStorageIconName(for url: URL) -> String {
        let name = url.lastPathComponent.lowercased()

        if name.contains("sharepoint") {
            return "building.2"
        }

        if name.contains("onedrive") || name.contains("google") {
            return "cloud"
        }

        return "externaldrive.badge.icloud"
    }

    private static func shouldShowCloudStorageLocation(_ url: URL) -> Bool {
        let name = url.lastPathComponent.lowercased()

        return !name.contains("cloudtemp")
            && !name.contains("tmp")
            && !name.contains("temporary")
            && !name.hasPrefix(".")
    }

    private static func isUsableSidebarDirectory(_ url: URL, fileManager: FileManager) -> Bool {
        guard let values = try? url.resourceValues(forKeys: [
            .isDirectoryKey,
            .isSymbolicLinkKey,
            .isAliasFileKey,
            .isReadableKey
        ]) else {
            return false
        }

        guard values.isDirectory == true,
              values.isSymbolicLink != true,
              values.isAliasFile != true,
              values.isReadable != false else {
            return false
        }

        return fileManager.fileExists(atPath: url.path)
    }

    private static func rootVolumeTitle() -> String {
        let rootURL = URL(fileURLWithPath: "/", isDirectory: true)
        let values = try? rootURL.resourceValues(forKeys: [.volumeNameKey])

        return values?.volumeName
            ?? FileManager.default.displayName(atPath: "/")
            .nilIfEmpty
            ?? "Macintosh HD"
    }

    private static func volumeSortRank(_ url: URL) -> Int {
        if url.path == "/" {
            return 0
        }

        let values = try? url.resourceValues(forKeys: [
            .volumeIsLocalKey,
            .volumeIsInternalKey,
            .volumeIsRemovableKey
        ])

        if values?.volumeIsLocal == false {
            return 30
        }

        if values?.volumeIsRemovable == true {
            return 20
        }

        if values?.volumeIsInternal == true {
            return 10
        }

        return 40
    }

    private static func cloudStorageSortRank(_ url: URL) -> Int {
        let name = url.lastPathComponent.lowercased()

        if name.contains("google") {
            return 100
        }

        if name.hasPrefix("onedrive-共有ライブラリ")
            || name.hasPrefix("onedrive-共有ライブラリ")
            || name.contains("sharepoint") {
            return 120
        }

        if name.contains("onedrive") {
            return 110
        }

        return 130
    }

    private static func isDirectory(_ url: URL, fileManager: FileManager) -> Bool {
        var isDirectory: ObjCBool = false
        return fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    private static func loadShowHiddenFiles() -> Bool {
        AppDefaults.migratedBool(
            forKey: showHiddenFilesDefaultsKey,
            legacyKeys: legacyShowHiddenFilesDefaultsKeys
        ) ?? false
    }

    private static func loadUserFavoriteFolders(defaultsKey: String, legacyDefaultsKeys: [String]) -> [URL] {
        let paths = AppDefaults.migratedStringArray(
            forKey: defaultsKey,
            legacyKeys: legacyDefaultsKeys
        ) ?? []
        return paths.map { URL(fileURLWithPath: $0, isDirectory: true).standardizedFileURL }
    }

    private static func loadServerConnections(defaultsKey: String, legacyDefaultsKeys: [String]) -> [ServerConnection] {
        guard let data = AppDefaults.migratedData(forKey: defaultsKey, legacyKeys: legacyDefaultsKeys),
              let connections = try? JSONDecoder().decode([ServerConnection].self, from: data) else {
            return []
        }

        return connections
    }

    private static func loadSidebarLocationOrder(defaultsKey: String, legacyDefaultsKeys: [String]) -> [String] {
        AppDefaults.migratedStringArray(
            forKey: defaultsKey,
            legacyKeys: legacyDefaultsKeys
        ) ?? []
    }

    private static func loadExternalTools(defaultsKey: String, legacyDefaultsKeys: [String]) -> [ExternalTool] {
        guard let data = AppDefaults.migratedData(forKey: defaultsKey, legacyKeys: legacyDefaultsKeys) else {
            return ExternalTool.defaultTools
        }

        return (try? JSONDecoder().decode([ExternalTool].self, from: data).map(\.normalized)) ?? ExternalTool.defaultTools
    }

    private static func orderedLocations(
        _ locations: [SidebarLocation],
        orderIDs: [String]
    ) -> [SidebarLocation] {
        guard !orderIDs.isEmpty else {
            return locations
        }

        let rankByID = Dictionary(uniqueKeysWithValues: orderIDs.enumerated().map { ($0.element, $0.offset) })

        return locations.enumerated()
            .sorted { left, right in
                let leftRank = rankByID[left.element.id]
                let rightRank = rankByID[right.element.id]

                switch (leftRank, rightRank) {
                case let (.some(leftRank), .some(rightRank)):
                    return leftRank < rightRank
                case (.some, .none):
                    return true
                case (.none, .some):
                    return false
                case (.none, .none):
                    return left.offset < right.offset
                }
            }
            .map(\.element)
    }

    private static func deduplicatedPreservingOrder(_ locations: [SidebarLocation]) -> [SidebarLocation] {
        var seenPaths: Set<String> = []
        var result: [SidebarLocation] = []

        for location in locations {
            let path = sidebarDeduplicationPath(for: location.url)

            if seenPaths.insert(path).inserted {
                result.append(location)
            }
        }

        return result
    }

    private static func deduplicatedLocations(_ locations: [SidebarLocation]) -> [SidebarLocation] {
        var seenPaths: Set<String> = []
        var result: [SidebarLocation] = []

        for location in locations {
            let path = sidebarDeduplicationPath(for: location.url)

            if seenPaths.insert(path).inserted {
                result.append(location)
            }
        }

        return result.sorted {
            if $0.title == "Mac" {
                return false
            }

            if $1.title == "Mac" {
                return true
            }

            return $0.title.localizedStandardCompare($1.title) == .orderedAscending
        }
    }

    private static func sidebarDeduplicationPath(for url: URL) -> String {
        if SFTPClient.isSFTPURL(url) || S3Client.isS3URL(url) {
            return url.absoluteString
        }

        return url
            .resolvingSymlinksInPath()
            .standardizedFileURL
            .path
    }

    private func sortedItems(_ values: [FileItem]) -> [FileItem] {
        values.sorted { left, right in
            if left.isDirectory != right.isDirectory {
                return left.isDirectory
            }

            let comparison: ComparisonResult

            switch sortColumn {
            case .name:
                comparison = left.displayName.localizedStandardCompare(right.displayName)
            case .modifiedAt:
                let leftDate = left.modifiedAt ?? .distantPast
                let rightDate = right.modifiedAt ?? .distantPast
                comparison = compare(leftDate, rightDate)
            case .size:
                comparison = compare(left.size ?? -1, right.size ?? -1)
            case .kind:
                comparison = left.kind.localizedStandardCompare(right.kind)
            }

            if comparison == .orderedSame {
                return left.displayName.localizedStandardCompare(right.displayName) == .orderedAscending
            }

            return sortAscending ? comparison == .orderedAscending : comparison == .orderedDescending
        }
    }

    private func groupDescriptor(for item: FileItem) -> (id: String, title: String) {
        switch groupMode {
        case .none:
            return (FileGroupMode.none.rawValue, "")
        case .kind:
            let title = item.isDirectory ? L10n.string("Folder") : L10n.string(item.kind)
            return ("kind-\(title)", title)
        case .modifiedDate:
            return modifiedDateGroupDescriptor(for: item.modifiedAt)
        case .size:
            return sizeGroupDescriptor(for: item)
        }
    }

    private func modifiedDateGroupDescriptor(for date: Date?) -> (id: String, title: String) {
        guard let date else {
            return ("date-none", L10n.string("No Date"))
        }

        let calendar = Calendar.current
        let now = Date()

        if calendar.isDateInToday(date) {
            return ("date-0-today", L10n.string("Today"))
        }

        if calendar.isDateInYesterday(date) {
            return ("date-1-yesterday", L10n.string("Yesterday"))
        }

        guard let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: date), to: calendar.startOfDay(for: now)).day else {
            return ("date-unknown", L10n.string("No Date"))
        }

        if days < 7 {
            return ("date-2-week", L10n.string("Previous 7 Days"))
        }

        if days < 30 {
            return ("date-3-month", L10n.string("Previous 30 Days"))
        }

        if calendar.component(.year, from: date) == calendar.component(.year, from: now) {
            return ("date-4-year", L10n.string("This Year"))
        }

        return ("date-5-older", L10n.string("Older"))
    }

    private func sizeGroupDescriptor(for item: FileItem) -> (id: String, title: String) {
        guard !item.isDirectory else {
            return ("size-0-folders", L10n.string("Folders"))
        }

        guard let size = item.size else {
            return ("size-1-none", L10n.string("No Size"))
        }

        switch size {
        case 0:
            return ("size-2-zero", L10n.string("Zero KB"))
        case 1..<(1_000_000):
            return ("size-3-small", L10n.string("Small"))
        case 1_000_000..<(100_000_000):
            return ("size-4-medium", L10n.string("Medium"))
        case 100_000_000..<(1_000_000_000):
            return ("size-5-large", L10n.string("Large"))
        default:
            return ("size-6-very-large", L10n.string("Very Large"))
        }
    }

    private func compare<T: Comparable>(_ left: T, _ right: T) -> ComparisonResult {
        if left < right {
            return .orderedAscending
        }

        if left > right {
            return .orderedDescending
        }

        return .orderedSame
    }

    private func uniqueDestinationURL(for sourceURL: URL, in destinationFolder: URL) -> URL {
        let filename = sourceURL.lastPathComponent
        let pathExtension = sourceURL.pathExtension
        let baseName: String

        if pathExtension.isEmpty {
            baseName = filename
        } else {
            baseName = (filename as NSString).deletingPathExtension
        }

        return uniqueURL(
            in: destinationFolder,
            baseName: baseName,
            pathExtension: pathExtension,
            copyStyle: true
        )
    }

    private func uniqueRemoteURL(
        in folder: URL,
        baseName: String,
        pathExtension: String,
        copyStyle: Bool
    ) -> URL {
        let existingNames = Set(items.map(\.name))

        func makeName(_ name: String) -> String {
            if pathExtension.isEmpty {
                return name
            }

            return "\(name).\(pathExtension)"
        }

        let firstName = makeName(baseName)

        guard existingNames.contains(firstName) else {
            return SFTPClient.childURL(named: firstName, in: folder)
        }

        var index = 2

        while true {
            let suffix = copyStyle
                ? (index == 2 ? " copy" : " copy \(index)")
                : " \(index)"
            let candidateName = makeName("\(baseName)\(suffix)")

            if !existingNames.contains(candidateName) {
                return SFTPClient.childURL(named: candidateName, in: folder)
            }

            index += 1
        }
    }

    private func uniqueS3URL(
        in folder: URL,
        baseName: String,
        pathExtension: String,
        isDirectory: Bool,
        copyStyle: Bool
    ) -> URL {
        let existingNames = Set(items.map(\.name))

        func makeName(_ name: String) -> String {
            if pathExtension.isEmpty {
                return name
            }

            return "\(name).\(pathExtension)"
        }

        let firstName = makeName(baseName)

        guard existingNames.contains(firstName) else {
            return S3Client.childURL(named: firstName, isDirectory: isDirectory, in: folder)
        }

        var index = 2

        while true {
            let suffix = copyStyle
                ? (index == 2 ? " copy" : " copy \(index)")
                : " \(index)"
            let candidateName = makeName("\(baseName)\(suffix)")

            if !existingNames.contains(candidateName) {
                return S3Client.childURL(named: candidateName, isDirectory: isDirectory, in: folder)
            }

            index += 1
        }
    }

    private func uniqueURL(
        in folder: URL,
        baseName: String,
        pathExtension: String,
        copyStyle: Bool
    ) -> URL {
        func makeURL(name: String) -> URL {
            if pathExtension.isEmpty {
                return folder.appendingPathComponent(name)
            }

            return folder.appendingPathComponent(name).appendingPathExtension(pathExtension)
        }

        let firstURL = makeURL(name: baseName)

        guard fileManager.fileExists(atPath: firstURL.path) else {
            return firstURL
        }

        var index = 2

        while true {
            let suffix: String

            if copyStyle {
                suffix = index == 2 ? " copy" : " copy \(index)"
            } else {
                suffix = " \(index)"
            }

            let candidateURL = makeURL(name: "\(baseName)\(suffix)")

            if !fileManager.fileExists(atPath: candidateURL.path) {
                return candidateURL
            }

            index += 1
        }
    }

    private func writeURLsToPasteboard(_ urls: [URL]) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects(urls.map { $0 as NSURL })
        pasteboard.setString(urls.map(\.path).joined(separator: "\n"), forType: .string)
    }

    private func readFileURLsFromPasteboard() -> [URL] {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [
            .urlReadingFileURLsOnly: true
        ]

        let objects = NSPasteboard.general.readObjects(
            forClasses: [NSURL.self],
            options: options
        ) as? [NSURL]

        return objects?.compactMap { $0 as URL } ?? []
    }

    private func downloadAndOpen(_ url: URL) {
        let destinationFolder = fileManager.temporaryDirectory
            .appendingPathComponent("ShodanaRemoteOpen", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)

        Task {
            do {
                try await SFTPClient.download(remoteURLs: [url], to: destinationFolder)
                NSWorkspace.shared.open(destinationFolder.appendingPathComponent(url.lastPathComponent))
            } catch {
                presentError(error, action: "Open SFTP item")
            }
        }
    }

    private func downloadAndOpenS3(_ url: URL) {
        let destinationFolder = fileManager.temporaryDirectory
            .appendingPathComponent("ShodanaRemoteOpen", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)

        Task {
            do {
                try await S3Client.download(remoteURLs: [url], to: destinationFolder)
                NSWorkspace.shared.open(destinationFolder.appendingPathComponent(url.lastPathComponent))
            } catch {
                presentError(error, action: "Open S3 item")
            }
        }
    }

    private func forwardTextAction(_ selector: Selector) -> Bool {
        NSApp.sendAction(selector, to: nil, from: nil)
    }

    private func addFavoriteFolderFromDrop(path: String?, errorMessage: String?) {
        if let errorMessage {
            presentMessage("Add favorite failed: \(errorMessage)")
            return
        }

        guard let path else {
            presentMessage("Add favorite failed: unsupported dropped item.")
            return
        }

        addFavoriteFolder(URL(fileURLWithPath: path, isDirectory: true))
    }

    private func dropItem(_ url: URL?, errorMessage: String?, into destinationFolder: URL) {
        if let errorMessage {
            presentMessage("Drop failed: \(errorMessage)")
            return
        }

        guard let url else {
            presentMessage("Drop failed: unsupported dropped item.")
            return
        }

        transfer([url], into: destinationFolder, mode: .copy)
    }

    private func dropURLs(_ urls: [URL], errorMessage: String?, into destinationFolder: URL) {
        if let errorMessage {
            presentMessage("Drop failed: \(errorMessage)")
            return
        }

        guard !urls.isEmpty else {
            presentMessage("Drop failed: unsupported dropped item.")
            return
        }

        transfer(urls, into: destinationFolder, mode: .copy)
    }

    private func saveUserFavoriteFolders() {
        let paths = userFavoriteFolders.map { $0.standardizedFileURL.path }
        UserDefaults.standard.set(paths, forKey: userFavoritesDefaultsKey)
    }

    private func saveServerConnections() {
        guard let data = try? JSONEncoder().encode(serverConnections) else {
            return
        }

        UserDefaults.standard.set(data, forKey: serverConnectionsDefaultsKey)
    }

    private func saveExternalTools() {
        guard let data = try? JSONEncoder().encode(externalTools) else {
            return
        }

        UserDefaults.standard.set(data, forKey: externalToolsDefaultsKey)
    }

    private func currentLocationIDs() -> [String]? {
        sidebarSections
            .first { $0.title == "Locations" }?
            .locations
            .map(\.id)
    }

    private func persistSidebarLocationOrder(_ ids: [String]) {
        sidebarLocationOrderIDs = ids
        UserDefaults.standard.set(ids, forKey: sidebarLocationOrderDefaultsKey)
        refreshSidebarLocations()
    }

    private func displayString(for url: URL) -> String {
        if SFTPClient.isSFTPURL(url) {
            return SFTPClient.displayString(for: url)
        }

        if S3Client.isS3URL(url) {
            return S3Client.displayString(for: url)
        }

        return url.path
    }

    private func isRemoteURL(_ url: URL) -> Bool {
        SFTPClient.isSFTPURL(url) || S3Client.isS3URL(url)
    }

    private nonisolated static func filePath(fromDroppedItem item: NSSecureCoding?) -> String? {
        if let url = item as? URL {
            return url.path
        }

        if let data = item as? Data, let value = String(data: data, encoding: .utf8) {
            return (URL(string: value) ?? URL(fileURLWithPath: value)).path
        }

        if let value = item as? String {
            return (URL(string: value) ?? URL(fileURLWithPath: value)).path
        }

        return nil
    }

    private nonisolated static func url(fromDroppedItem item: NSSecureCoding?) -> URL? {
        if let url = item as? URL {
            return url
        }

        if let url = item as? NSURL {
            return url as URL
        }

        if let data = item as? Data, let value = String(data: data, encoding: .utf8) {
            return url(fromDroppedString: value)
        }

        if let value = item as? String {
            return url(fromDroppedString: value)
        }

        return nil
    }

    private nonisolated static func url(fromDroppedString value: String) -> URL? {
        let trimmedValue = value.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmedValue.isEmpty else {
            return nil
        }

        if let url = URL(string: trimmedValue),
           url.scheme != nil {
            return url
        }

        return URL(fileURLWithPath: trimmedValue)
    }

    private nonisolated static func urlsFromDroppedURLList(_ value: String) -> [URL] {
        value
            .split(whereSeparator: \.isNewline)
            .compactMap { url(fromDroppedString: String($0)) }
    }

    private nonisolated static func filenamesPasteboardData(for urls: [URL]) -> Data? {
        try? PropertyListSerialization.data(
            fromPropertyList: urls.map(\.path),
            format: .binary,
            options: 0
        )
    }

    private nonisolated static func urlsFromFilenamesPasteboardData(_ data: Data) -> [URL] {
        guard let propertyList = try? PropertyListSerialization.propertyList(
            from: data,
            options: [],
            format: nil
        ) else {
            return []
        }

        if let paths = propertyList as? [String] {
            return paths.map { URL(fileURLWithPath: $0) }
        }

        return []
    }

    private func openDirectory(_ url: URL, in terminalApp: TerminalApp) {
        let command: String

        do {
            command = try terminalCommand(for: url)
        } catch {
            presentError(error, action: terminalApp == .iTerm ? "Open in iTerm" : "Open in Terminal")
            return
        }

        let escapedCommand = appleScriptEscaped(command)

        switch terminalApp {
        case .terminal:
            runAppleScript(
                """
                tell application "Terminal"
                    activate
                    do script "\(escapedCommand)"
                end tell
                """,
                action: "Open in Terminal",
                automationTarget: "Terminal"
            )
        case .iTerm:
            guard isITermAvailable else {
                presentMessage("iTerm is not installed.")
                return
            }

            runAppleScript(
                """
                tell application "iTerm"
                    activate
                    create window with default profile
                    tell current session of current window
                        write text "\(escapedCommand)"
                    end tell
                end tell
                """,
                action: "Open in iTerm",
                automationTarget: "iTerm"
            )
        }
    }

    private func terminalCommand(for url: URL) throws -> String {
        if SFTPClient.isSFTPURL(url) {
            return try remoteTerminalCommand(for: url)
        }

        if S3Client.isS3URL(url) {
            throw S3ClientError.commandFailed("Open in Terminal is not available for S3 locations.")
        }

        let directoryURL = directoryURL(for: url)
        return "cd \(shellQuoted(directoryURL.path))"
    }

    private func remoteTerminalCommand(for url: URL) throws -> String {
        let spec = try SFTPClient.connectionSpec(for: url)
        let remotePath = remoteDirectoryPath(for: url)
        let remoteCommand = "cd \(shellQuoted(remotePath)) && exec ${SHELL:-/bin/sh} -l"
        var baseArguments = ["ssh"]
        var warningSuppressedArguments = ["ssh", "-o", "WarnWeakCrypto=no-pq-kex"]
        var probeArguments = ["ssh", "-G", "-o", "WarnWeakCrypto=no-pq-kex"]

        if let port = spec.port {
            baseArguments.append(contentsOf: ["-p", String(port)])
            warningSuppressedArguments.append(contentsOf: ["-p", String(port)])
            probeArguments.append(contentsOf: ["-p", String(port)])
        }

        baseArguments.append(contentsOf: ["-t", spec.target, remoteCommand])
        warningSuppressedArguments.append(contentsOf: ["-t", spec.target, remoteCommand])
        probeArguments.append(spec.target)

        let probeCommand = probeArguments.map(shellQuoted).joined(separator: " ")
        let warningSuppressedCommand = warningSuppressedArguments.map(shellQuoted).joined(separator: " ")
        let baseCommand = baseArguments.map(shellQuoted).joined(separator: " ")

        return "if \(probeCommand) >/dev/null 2>&1; then exec \(warningSuppressedCommand); else exec \(baseCommand); fi"
    }

    private func remoteDirectoryPath(for url: URL) -> String {
        if let item = items.first(where: { $0.url == url }),
           !item.canNavigateInto {
            return SFTPClient.remotePath(for: SFTPClient.parentURL(for: url))
        }

        return SFTPClient.remotePath(for: url)
    }

    private func openFolderWithApplicationTool(_ tool: ExternalTool) {
        guard let folderURL = targetURL(for: tool), !isRemoteURL(folderURL) else {
            presentMessage("Select one local folder to open in \(tool.title).")
            return
        }

        guard let applicationURL = applicationURL(for: tool) else {
            presentMessage("\(tool.title) is not installed.")
            return
        }

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true

        NSWorkspace.shared.open(
            [folderURL],
            withApplicationAt: applicationURL,
            configuration: configuration
        ) { [weak self] _, error in
            guard let error else {
                return
            }

            Task { @MainActor in
                self?.presentError(error, action: "Open in \(tool.title)")
            }
        }
    }

    private func targetURL(for tool: ExternalTool) -> URL? {
        switch tool.target {
        case .currentFolder:
            return currentURL
        case .selectedFolder:
            guard selectedIDs.count == 1,
                  let item = selectedItems.first,
                  item.canNavigateInto else {
                return nil
            }

            return item.url
        }
    }

    private func applicationURL(for tool: ExternalTool) -> URL? {
        if let applicationPath = tool.applicationPath,
           fileManager.fileExists(atPath: applicationPath) {
            return URL(fileURLWithPath: applicationPath)
        }

        switch tool.kind {
        case .terminal:
            return terminalApplicationURL
        case .iTerm:
            return iTermApplicationURL
        case .application:
            break
        }

        for bundleIdentifier in tool.bundleIdentifiers {
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) {
                return url
            }
        }

        return nil
    }

    private func directoryURL(for url: URL) -> URL {
        var isDirectory: ObjCBool = false

        if fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue {
            return url
        }

        return url.deletingLastPathComponent()
    }

    private func runAppleScript(_ source: String, action: String, automationTarget: String) {
        guard let script = NSAppleScript(source: source) else {
            presentMessage("\(action) failed: could not build AppleScript.")
            return
        }

        var errorInfo: NSDictionary?
        script.executeAndReturnError(&errorInfo)

        if let errorInfo {
            let message = errorInfo["NSAppleScriptErrorMessage"] as? String
                ?? errorInfo.description
            let errorNumber = errorInfo["NSAppleScriptErrorNumber"] as? Int

            if errorNumber == -1743 || message.localizedCaseInsensitiveContains("not authorized") {
                presentMessage(
                    "\(action) needs permission to control \(automationTarget). Open System Settings > Privacy & Security > Automation, then allow Shodana to control \(automationTarget)."
                )
                return
            }

            presentMessage("\(action) failed: \(message)")
        }
    }

    private func shellQuoted(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
    }

    private func appleScriptEscaped(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    private nonisolated func mountNetworkURL(_ url: URL) async -> (status: Int32, mountURLs: [URL]) {
        await Task.detached(priority: .userInitiated) {
            var unmanagedMountpoints: Unmanaged<CFArray>?
            let openOptions = NSMutableDictionary()
            openOptions["UIOption"] = "AllowUI"

            let status = NetFSMountURLSync(
                url as CFURL,
                nil,
                nil,
                nil,
                openOptions,
                nil,
                &unmanagedMountpoints
            )

            guard status == 0 else {
                if let unmanagedMountpoints {
                    _ = unmanagedMountpoints.takeRetainedValue()
                }

                return (status, [])
            }

            let mountpointValues: [String]

            if let unmanagedMountpoints {
                let mountpoints = unmanagedMountpoints.takeRetainedValue() as NSArray
                mountpointValues = mountpoints.compactMap { $0 as? String }
            } else {
                mountpointValues = []
            }

            let mountURLs = mountpointValues.map { URL(fileURLWithPath: $0, isDirectory: true) }

            return (status, mountURLs)
        }.value
    }

    private func presentError(_ error: Error, action: String) {
        errorMessage = L10n.format("error.action_failed", L10n.string(action), error.localizedDescription)
    }

    private func presentMessage(_ message: String) {
        errorMessage = message
    }
}

private extension NSResponder {
    var isEditableTextInputResponder: Bool {
        var current: NSResponder? = self
        var depth = 0

        while let responder = current, depth < 16 {
            if let textView = responder as? NSTextView, textView.isEditable {
                return true
            }

            if let textField = responder as? NSTextField, textField.isEditable {
                return true
            }

            current = responder.nextResponder
            depth += 1
        }

        return false
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }

    func appendingRemotePathComponent(_ component: String) -> String {
        if self == "/" {
            return "/\(component)"
        }

        return "\(self)/\(component)"
    }

    func appendingS3PrefixComponent(_ component: String) -> String {
        let trimmedComponent = component.trimmingCharacters(in: CharacterSet(charactersIn: "/"))

        guard !trimmedComponent.isEmpty else {
            return self
        }

        if isEmpty {
            return trimmedComponent
        }

        return hasSuffix("/") ? "\(self)\(trimmedComponent)" : "\(self)/\(trimmedComponent)"
    }

    var trimmingTrailingSlash: String {
        var result = self

        while result.hasSuffix("/") {
            result.removeLast()
        }

        return result
    }
}
