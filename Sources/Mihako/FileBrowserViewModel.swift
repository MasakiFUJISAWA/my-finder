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

    private let fileManager = FileManager.default
    private let userFavoritesDefaultsKey = "Mihako.userFavoriteFolders"
    private let legacyUserFavoritesDefaultsKey = "My" + "Finder.userFavoriteFolders"
    private let serverConnectionsDefaultsKey = "Mihako.serverConnections"
    private let legacyServerConnectionsDefaultsKey = "My" + "Finder.serverConnections"
    private var history: [URL]
    private var historyIndex = 0
    private var selectionAnchorURL: URL?
    private var reconnectingServerIDs: Set<String> = []

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
        currentURL.path != "/"
    }

    var selectedItems: [FileItem] {
        items.filter { selectedIDs.contains($0.url) }
    }

    var selectedURLs: [URL] {
        selectedItems.map(\.url)
    }

    var selectedFolderURL: URL? {
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

    var breadcrumbs: [Breadcrumb] {
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

    func reload() {
        refreshSidebarLocations()

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

    func submitAddress() {
        let rawPath = addressText.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !rawPath.isEmpty else {
            addressText = currentURL.path
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
        let targetURL = url.standardizedFileURL
        var isDirectory: ObjCBool = false

        guard fileManager.fileExists(atPath: targetURL.path, isDirectory: &isDirectory) else {
            addressText = currentURL.path
            presentMessage("Path does not exist: \(targetURL.path)")
            return
        }

        guard isDirectory.boolValue else {
            NSWorkspace.shared.open(targetURL)
            addressText = currentURL.path
            return
        }

        currentURL = targetURL
        addressText = targetURL.path
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

        navigate(to: currentURL.deletingLastPathComponent())
    }

    func open(_ item: FileItem) {
        if item.canNavigateInto {
            navigate(to: item.url)
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
            let displayName = serverConnection(kind: kind, url: connectionURL)?.displayName
            mountServerConnection(kind: kind, url: connectionURL, displayName: displayName, silentFailure: true)
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

        let provider = NSItemProvider(object: item.url as NSURL)
        let fileURLString = item.url.absoluteString
        provider.suggestedName = item.displayName
        provider.registerDataRepresentation(
            forTypeIdentifier: UTType.fileURL.identifier,
            visibility: .all
        ) { completion in
            completion(fileURLString.data(using: .utf8), nil)
            return nil
        }
        provider.registerDataRepresentation(
            forTypeIdentifier: UTType.plainText.identifier,
            visibility: .all
        ) { completion in
            completion(item.url.path.data(using: .utf8), nil)
            return nil
        }

        return provider
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

    func duplicate(_ item: FileItem) {
        do {
            let destinationURL = uniqueDestinationURL(for: item.url, in: item.url.deletingLastPathComponent())
            try fileManager.copyItem(at: item.url, to: destinationURL)
            reload()
            selectOnly(destinationURL)
        } catch {
            presentError(error, action: "Duplicate")
        }
    }

    func trashSelection() {
        let urls = selectedURLs

        guard !urls.isEmpty else {
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

    func copyPath(_ item: FileItem) {
        copyPath(item.url)
    }

    func copyPath(_ url: URL) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(url.path, forType: .string)
    }

    func revealInFinder(_ item: FileItem) {
        revealInFinder(item.url)
    }

    func revealInFinder(_ url: URL) {
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
            serverConnections: serverConnections
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
        isConnectServerDialogPresented = true
    }

    func commitConnectServerDialog() {
        let address = connectServerAddress
        let displayName = connectServerDisplayName.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        isConnectServerDialogPresented = false

        connectToServer(kind: connectProtocol, address: address, displayName: displayName)
    }

    func cancelConnectServerDialog() {
        isConnectServerDialogPresented = false
    }

    func connectToServer(kind selectedKind: RemoteConnectionKind, address: String, displayName: String?) {
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

        mountServerConnection(kind: kind, url: url, displayName: displayName, silentFailure: false)
    }

    func clearError() {
        errorMessage = nil
    }

    private static func makeSidebarSections(
        userFavoriteFolders: [URL],
        serverConnections: [ServerConnection]
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
            serverConnections: serverConnections
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
        serverConnections: [ServerConnection]
    ) -> [SidebarLocation] {
        deduplicatedPreservingOrder(
            computerLocations()
                + connectedServerLocations(serverConnections)
                + mountedVolumeLocations()
                + cloudStorageLocations(homeURL: homeURL)
        )
    }

    private static func connectedServerLocations(_ connections: [ServerConnection]) -> [SidebarLocation] {
        connections.compactMap { connection in
            guard let connectionURL = URL(string: connection.urlString) else {
                return nil
            }
            let kind = connection.kind

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
                silentFailure: true
            )
        }
    }

    private func mountServerConnection(
        kind: RemoteConnectionKind,
        url: URL,
        displayName: String?,
        silentFailure: Bool
    ) {
        let connectionID = serverConnectionID(kind: kind, urlString: url.absoluteString)

        guard reconnectingServerIDs.insert(connectionID).inserted else {
            return
        }

        guard kind.canMountThroughSystem else {
            reconnectingServerIDs.remove(connectionID)
            upsertServerConnection(kind: kind, url: url, displayName: displayName, mountURL: nil, isUnavailable: true)
            refreshSidebarLocations()
            return
        }

        Task {
            let result = await mountNetworkURL(url)
            reconnectingServerIDs.remove(connectionID)

            if result.status == 0, let mountURL = result.mountURLs.first {
                upsertServerConnection(
                    kind: kind,
                    url: url,
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

            if hasServerConnection(kind: kind, url: url) {
                upsertServerConnection(
                    kind: kind,
                    url: url,
                    displayName: displayName,
                    mountURL: nil,
                    isUnavailable: true
                )
                refreshSidebarLocations()
            }

            if !silentFailure, result.status != -128 {
                presentMessage("Could not connect server: \(url.absoluteString) (status \(result.status))")
            }
        }
    }

    private func isServerConnectionAvailable(_ connection: ServerConnection) -> Bool {
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
        displayName: String?,
        mountURL: URL?,
        isUnavailable: Bool
    ) {
        let urlString = url.absoluteString
        let mountPath = mountURL?.standardizedFileURL.path
        let id = serverConnectionID(kind: kind, urlString: urlString)

        if let index = serverConnections.firstIndex(where: {
            serverConnectionID(kind: $0.kind, urlString: $0.urlString) == id
        }) {
            serverConnections[index].kind = kind
            if let displayName {
                serverConnections[index].displayName = displayName
            }
            serverConnections[index].mountPath = mountPath
            serverConnections[index].isUnavailable = isUnavailable
        } else {
            serverConnections.append(
                ServerConnection(
                    kind: kind,
                    urlString: urlString,
                    displayName: displayName,
                    mountPath: mountPath,
                    isUnavailable: isUnavailable
                )
            )
        }

        saveServerConnections()
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
        url
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

    private func openDirectory(_ url: URL, in terminalApp: TerminalApp) {
        let directoryURL = directoryURL(for: url)
        let command = "cd \(shellQuoted(directoryURL.path))"
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
                action: "Open in Terminal"
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
                action: "Open in iTerm"
            )
        }
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

    private func runAppleScript(_ source: String, action: String) {
        guard let script = NSAppleScript(source: source) else {
            presentMessage("\(action) failed: could not build AppleScript.")
            return
        }

        var errorInfo: NSDictionary?
        script.executeAndReturnError(&errorInfo)

        if let errorInfo {
            let message = errorInfo["NSAppleScriptErrorMessage"] as? String
                ?? errorInfo.description
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
}
