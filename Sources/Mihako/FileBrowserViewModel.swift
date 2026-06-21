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
    @Published var showHiddenFiles = false {
        didSet {
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
    @Published private(set) var userFavoriteFolders: [URL] = []
    @Published private(set) var serverConnections: [ServerConnection] = []
    @Published var isConnectServerDialogPresented = false
    @Published var connectProtocol: RemoteConnectionKind = .smb
    @Published var connectServerAddress = "smb://"
    @Published var connectServerDisplayName = ""
    @Published var connectAWSProfile = ""
    @Published private(set) var awsProfiles: [String] = []

    private let fileManager = FileManager.default
    private let userFavoritesDefaultsKey = "Mihako.userFavoriteFolders"
    private let legacyUserFavoritesDefaultsKey = "My" + "Finder.userFavoriteFolders"
    private let serverConnectionsDefaultsKey = "Mihako.serverConnections"
    private let legacyServerConnectionsDefaultsKey = "My" + "Finder.serverConnections"
    private let sidebarLocationOrderDefaultsKey = "Mihako.sidebarLocationOrder"
    private var history: [URL]
    private var historyIndex = 0
    private var selectionAnchorURL: URL?
    private var reconnectingServerIDs: Set<String> = []
    private var sidebarLocationOrderIDs: [String] = []
    private var remoteReloadTask: Task<Void, Never>?

    private enum TerminalApp {
        case terminal
        case iTerm
    }

    private enum ExternalEditor {
        case webStorm
        case pyCharm
        case vsCode

        var displayName: String {
            switch self {
            case .webStorm:
                return "WebStorm"
            case .pyCharm:
                return "PyCharm"
            case .vsCode:
                return "VSCode"
            }
        }

        var bundleIdentifiers: [String] {
            switch self {
            case .webStorm:
                return ["com.jetbrains.WebStorm"]
            case .pyCharm:
                return ["com.jetbrains.pycharm", "com.jetbrains.pycharm.ce"]
            case .vsCode:
                return ["com.microsoft.VSCode", "com.microsoft.VSCodeInsiders"]
            }
        }
    }

    private var iTermApplicationURL: URL? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.googlecode.iterm2")
    }

    init(startURL: URL = FileManager.default.homeDirectoryForCurrentUser) {
        let initialURL = startURL.standardizedFileURL
        currentURL = initialURL
        addressText = initialURL.path
        history = [initialURL]
        userFavoriteFolders = Self.loadUserFavoriteFolders(
            defaultsKey: userFavoritesDefaultsKey,
            legacyDefaultsKey: legacyUserFavoritesDefaultsKey
        )
        serverConnections = Self.loadServerConnections(
            defaultsKey: serverConnectionsDefaultsKey,
            legacyDefaultsKey: legacyServerConnectionsDefaultsKey
        )
        sidebarLocationOrderIDs = Self.loadSidebarLocationOrder(defaultsKey: sidebarLocationOrderDefaultsKey)
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

    var selectedItems: [FileItem] {
        items.filter { selectedIDs.contains($0.url) }
    }

    var selectedURLs: [URL] {
        selectedItems.map(\.url)
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

    var canOpenSelectedFolderInWebStorm: Bool {
        canOpenSelectedFolder(in: .webStorm)
    }

    var canOpenSelectedFolderInPyCharm: Bool {
        canOpenSelectedFolder(in: .pyCharm)
    }

    var canOpenSelectedFolderInVSCode: Bool {
        canOpenSelectedFolder(in: .vsCode)
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

        do {
            let options: FileManager.DirectoryEnumerationOptions = showHiddenFiles ? [] : [.skipsHiddenFiles]
            let urls = try fileManager.contentsOfDirectory(
                at: currentURL,
                includingPropertiesForKeys: keys,
                options: options
            )

            let loadedItems = try urls.map(FileItem.load)
            items = sortedItems(loadedItems)
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
        if item.canNavigateInto {
            navigate(to: item.url)
        } else if SFTPClient.isSFTPURL(item.url) {
            downloadAndOpen(item.url)
        } else if S3Client.isS3URL(item.url) {
            downloadAndOpenS3(item.url)
        } else {
            NSWorkspace.shared.open(item.url)
        }
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

        guard let anchorIndex = items.firstIndex(where: { $0.url == anchorURL }),
              let endIndex = items.firstIndex(where: { $0.url == url }) else {
            selectOnly(url)
            return
        }

        let bounds = anchorIndex <= endIndex
            ? anchorIndex...endIndex
            : endIndex...anchorIndex

        selectedIDs = Set(items[bounds].map(\.url))
        selectionAnchorURL = anchorURL
    }

    private func firstSelectedURLInDisplayOrder() -> URL? {
        items.first { selectedIDs.contains($0.url) }?.url
    }

    func dragProvider(for item: FileItem) -> NSItemProvider {
        select(item)

        let provider: NSItemProvider
        let itemURLString = item.url.absoluteString

        if SFTPClient.isSFTPURL(item.url) {
            provider = NSItemProvider()
            provider.registerDataRepresentation(
                forTypeIdentifier: MihakoTransferType.sftpURL,
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
                forTypeIdentifier: MihakoTransferType.s3URL,
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

    func dropItems(from providers: [NSItemProvider], into destinationFolder: URL) -> Bool {
        var acceptedDrop = false

        for provider in providers {
            guard let typeIdentifier = MihakoTransferType.urlDropTypeIdentifiers.first(where: {
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
        guard !isTextInputActive else {
            forwardTextAction(#selector(NSText.cut(_:)))
            return
        }

        cutSelection()
    }

    func handleFileCopyShortcut() {
        guard !isTextInputActive else {
            forwardTextAction(#selector(NSText.copy(_:)))
            return
        }

        copySelection()
    }

    func handleFilePasteShortcut() {
        guard !isTextInputActive else {
            forwardTextAction(#selector(NSText.paste(_:)))
            return
        }

        pasteIntoCurrentFolder()
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

    func openSelectedFolderInWebStorm() {
        openSelectedFolder(in: .webStorm)
    }

    func openSelectedFolderInPyCharm() {
        openSelectedFolder(in: .pyCharm)
    }

    func openSelectedFolderInVSCode() {
        openSelectedFolder(in: .vsCode)
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
        let suffix = isUnavailable ? " unavailable" : ""
        return "\(kind.displayName) - \(name)\(suffix)"
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

        let suffix = isUnavailable ? " unavailable" : ""
        return "\(trimmedDisplayName)\(suffix)"
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

    private static func loadUserFavoriteFolders(defaultsKey: String, legacyDefaultsKey: String) -> [URL] {
        let defaults = UserDefaults.standard
        let storedPaths = defaults.stringArray(forKey: defaultsKey)
        let legacyPaths = storedPaths == nil ? defaults.stringArray(forKey: legacyDefaultsKey) : nil
        let paths = storedPaths ?? legacyPaths ?? []

        if storedPaths == nil, let legacyPaths {
            defaults.set(legacyPaths, forKey: defaultsKey)
        }

        return paths.map { URL(fileURLWithPath: $0, isDirectory: true).standardizedFileURL }
    }

    private static func loadServerConnections(defaultsKey: String, legacyDefaultsKey: String) -> [ServerConnection] {
        let defaults = UserDefaults.standard
        let storedData = defaults.data(forKey: defaultsKey)
        let legacyData = storedData == nil ? defaults.data(forKey: legacyDefaultsKey) : nil

        guard let data = storedData ?? legacyData,
              let connections = try? JSONDecoder().decode([ServerConnection].self, from: data) else {
            return []
        }

        if storedData == nil, let legacyData {
            defaults.set(legacyData, forKey: defaultsKey)
        }

        return connections
    }

    private static func loadSidebarLocationOrder(defaultsKey: String) -> [String] {
        UserDefaults.standard.stringArray(forKey: defaultsKey) ?? []
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
            .appendingPathComponent("MihakoRemoteOpen", isDirectory: true)
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
            .appendingPathComponent("MihakoRemoteOpen", isDirectory: true)
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

    private func forwardTextAction(_ selector: Selector) {
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

    private func openSelectedFolder(in editor: ExternalEditor) {
        guard let folderURL = selectedFolderURL else {
            presentMessage("Select one folder to open in \(editor.displayName).")
            return
        }

        guard let applicationURL = applicationURL(for: editor) else {
            presentMessage("\(editor.displayName) is not installed.")
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
                self?.presentError(error, action: "Open in \(editor.displayName)")
            }
        }
    }

    private func canOpenSelectedFolder(in editor: ExternalEditor) -> Bool {
        selectedFolderURL != nil && applicationURL(for: editor) != nil
    }

    private func applicationURL(for editor: ExternalEditor) -> URL? {
        for bundleIdentifier in editor.bundleIdentifiers {
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
                    "\(action) needs permission to control \(automationTarget). Open System Settings > Privacy & Security > Automation, then allow Mihako to control \(automationTarget)."
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
        errorMessage = "\(action) failed: \(error.localizedDescription)"
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
