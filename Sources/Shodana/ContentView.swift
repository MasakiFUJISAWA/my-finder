import AppKit
import QuickLookThumbnailing
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @EnvironmentObject private var browser: FileBrowserViewModel
    @StateObject private var secondaryBrowser = FileBrowserViewModel(reconnectSavedServers: false)
    @State private var sidebarWidth: CGFloat = 300
    @State private var pasteboardShortcutMonitor: Any?
    @State private var hostingWindow: NSWindow?
    @State private var tabs: [BrowserTab] = []
    @State private var selectedTabID: UUID?
    @State private var isSwitchingTabs = false
    @State private var isDualPaneEnabled = false
    @State private var isFolderCompareSyncPresented = false

    private let minimumSidebarWidth: CGFloat = 220
    private let preferredMaximumSidebarWidth: CGFloat = 560
    private let resizeHandleWidth: CGFloat = 8
    private let minimumFileBrowserWidth: CGFloat = 760
    private let minimumFileBrowserHeight: CGFloat = 520
    private let minimumWindowHeight: CGFloat = 580

    private var minimumWindowWidth: CGFloat {
        minimumSidebarWidth + resizeHandleWidth + minimumFileBrowserWidth
    }

    var body: some View {
        GeometryReader { proxy in
            let availableWidth = max(proxy.size.width, minimumWindowWidth)
            let availableHeight = max(proxy.size.height, minimumWindowHeight)
            let maximumSidebarWidth = sidebarMaximumWidth(for: availableWidth)
            let actualSidebarWidth = clampedSidebarWidth(maximumWidth: maximumSidebarWidth)

            HStack(spacing: 0) {
                SidebarView()
                    .frame(width: actualSidebarWidth, alignment: .leading)
                    .frame(maxHeight: .infinity)
                    .clipped()

                SidebarResizeHandle(
                    width: sidebarWidthBinding(maximumWidth: maximumSidebarWidth),
                    minimumWidth: minimumSidebarWidth,
                    maximumWidth: maximumSidebarWidth
                )

                VStack(spacing: 0) {
                    BrowserTabBar(
                        tabs: tabs,
                        selectedTabID: selectedTabID,
                        isDualPaneEnabled: isDualPaneEnabled,
                        onSelect: selectTab,
                        onAdd: addTab,
                        onClose: closeTab,
                        onToggleDualPane: toggleDualPane,
                        onCompareSync: {
                            isFolderCompareSyncPresented = true
                        }
                    )

                    Divider()

                    if isDualPaneEnabled {
                        HSplitView {
                            BrowserPaneView()
                                .environmentObject(browser)

                            BrowserPaneView()
                                .environmentObject(secondaryBrowser)
                        }
                    } else {
                        BrowserPaneView()
                            .environmentObject(browser)
                    }
                }
                .frame(minWidth: minimumFileBrowserWidth, minHeight: minimumFileBrowserHeight)
                .layoutPriority(1)
            }
            .frame(width: availableWidth, height: availableHeight, alignment: .leading)
        }
        .frame(minWidth: minimumWindowWidth, minHeight: minimumWindowHeight, alignment: .leading)
        .background {
            WindowReader(window: $hostingWindow)
        }
        .onAppear {
            initializeTabsIfNeeded()
            installPasteboardShortcutMonitor()
        }
        .onChange(of: browser.currentURL) { _, newURL in
            updateSelectedTab(with: newURL)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { notification in
            guard notification.object as? NSWindow === hostingWindow else {
                return
            }

            persistTabs()
        }
        .onDisappear {
            persistTabs()
            removePasteboardShortcutMonitor()
        }
        .sheet(isPresented: $isFolderCompareSyncPresented) {
            FolderCompareSyncSheet(
                leftInitialURL: browser.currentURL,
                rightInitialURL: isDualPaneEnabled ? secondaryBrowser.currentURL : browser.currentURL,
                showHiddenFiles: browser.showHiddenFiles,
                locationChoices: folderCompareLocationChoices()
            )
        }
    }

    private func sidebarMaximumWidth(for availableWidth: CGFloat) -> CGFloat {
        let contentAwareMaximum = availableWidth - resizeHandleWidth - minimumFileBrowserWidth
        return max(minimumSidebarWidth, min(preferredMaximumSidebarWidth, contentAwareMaximum))
    }

    private func clampedSidebarWidth(maximumWidth: CGFloat) -> CGFloat {
        min(max(sidebarWidth, minimumSidebarWidth), maximumWidth)
    }

    private func sidebarWidthBinding(maximumWidth: CGFloat) -> Binding<CGFloat> {
        Binding(
            get: {
                clampedSidebarWidth(maximumWidth: maximumWidth)
            },
            set: { newValue in
                sidebarWidth = min(max(newValue, minimumSidebarWidth), maximumWidth)
            }
        )
    }

    private func initializeTabsIfNeeded() {
        guard tabs.isEmpty else {
            return
        }

        if let restoredState = BrowserTabSessionStore.restoreOnceForLaunch() {
            tabs = restoredState.tabs
            selectedTabID = restoredState.selectedTabID

            if let selectedTab = restoredState.selectedTab {
                isSwitchingTabs = true
                browser.navigate(to: selectedTab.url, recordHistory: false)

                DispatchQueue.main.async {
                    isSwitchingTabs = false
                }
            }
        } else {
            let tab = BrowserTab(url: browser.currentURL)
            tabs = [tab]
            selectedTabID = tab.id
            persistTabs()
        }
    }

    private func updateSelectedTab(with url: URL) {
        guard !isSwitchingTabs,
              let selectedTabID,
              let index = tabs.firstIndex(where: { $0.id == selectedTabID }) else {
            return
        }

        tabs[index].url = url
        persistTabs()
    }

    private func selectTab(_ tab: BrowserTab) {
        guard selectedTabID != tab.id else {
            return
        }

        isSwitchingTabs = true
        selectedTabID = tab.id
        persistTabs()
        browser.navigate(to: tab.url)

        DispatchQueue.main.async {
            isSwitchingTabs = false
        }
    }

    private func addTab() {
        let tab = BrowserTab(url: browser.currentURL)
        tabs.append(tab)
        selectedTabID = tab.id
        persistTabs()
    }

    private func closeTab(_ tab: BrowserTab) {
        guard tabs.count > 1,
              let index = tabs.firstIndex(where: { $0.id == tab.id }) else {
            return
        }

        let wasSelected = selectedTabID == tab.id
        tabs.remove(at: index)

        if wasSelected {
            let nextIndex = min(index, tabs.count - 1)
            selectTab(tabs[nextIndex])
        } else {
            persistTabs()
        }
    }

    private func persistTabs() {
        BrowserTabSessionStore.save(tabs: tabs, selectedTabID: selectedTabID)
    }

    private func toggleDualPane() {
        isDualPaneEnabled.toggle()

        if isDualPaneEnabled {
            secondaryBrowser.navigate(to: browser.currentURL)
        }
    }

    private func folderCompareLocationChoices() -> [FolderCompareLocationChoice] {
        var choices: [FolderCompareLocationChoice] = []
        var seenIDs = Set<String>()

        func appendChoice(sectionTitle: String, title: String, url: URL) {
            let id = folderCompareLocationID(for: url)

            guard seenIDs.insert(id).inserted else {
                return
            }

            choices.append(
                FolderCompareLocationChoice(
                    sectionTitle: sectionTitle,
                    title: title,
                    url: url
                )
            )
        }

        appendChoice(
            sectionTitle: "Current Panes",
            title: "Left Pane",
            url: browser.currentURL
        )

        appendChoice(
            sectionTitle: "Current Panes",
            title: "Right Pane",
            url: isDualPaneEnabled ? secondaryBrowser.currentURL : browser.currentURL
        )

        for section in browser.sidebarSections {
            for location in section.locations where !location.isUnavailable {
                appendChoice(
                    sectionTitle: section.title,
                    title: location.title,
                    url: location.url
                )
            }
        }

        return choices
    }

    private func folderCompareLocationID(for url: URL) -> String {
        if url.isFileURL {
            return url.standardizedFileURL.path
        }

        return url.absoluteString
    }

    private func installPasteboardShortcutMonitor() {
        guard pasteboardShortcutMonitor == nil else {
            return
        }

        pasteboardShortcutMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if shouldHandleFileSelectionNavigation(event) {
                browser.extendSelectionByKeyboard(offset: event.keyCode == 126 ? -1 : 1)
                return nil
            }

            guard shouldHandleFilePasteboardShortcut(event) else {
                return event
            }

            switch event.charactersIgnoringModifiers?.lowercased() {
            case "x":
                browser.cutSelection()
                return nil
            case "c":
                browser.copySelection()
                return nil
            case "v":
                browser.pasteIntoCurrentFolder()
                return nil
            default:
                return event
            }
        }
    }

    private func removePasteboardShortcutMonitor() {
        if let pasteboardShortcutMonitor {
            NSEvent.removeMonitor(pasteboardShortcutMonitor)
            self.pasteboardShortcutMonitor = nil
        }
    }

    private func shouldHandleFilePasteboardShortcut(_ event: NSEvent) -> Bool {
        guard hostingWindow == nil || hostingWindow === NSApp.keyWindow else {
            return false
        }

        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

        guard flags.contains(.command),
              !flags.contains(.option),
              !flags.contains(.control),
              ["x", "c", "v"].contains(event.charactersIgnoringModifiers?.lowercased() ?? "") else {
            return false
        }

        return !browser.isTextInputActive
    }

    private func shouldHandleFileSelectionNavigation(_ event: NSEvent) -> Bool {
        guard hostingWindow == nil || hostingWindow === NSApp.keyWindow else {
            return false
        }

        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

        guard flags.contains(.shift),
              !flags.contains(.command),
              !flags.contains(.option),
              !flags.contains(.control),
              event.keyCode == 125 || event.keyCode == 126 else {
            return false
        }

        return !browser.isTextInputActive
    }
}

@MainActor
enum BrowserTabSessionStore {
    struct RestoredState {
        let tabs: [BrowserTab]
        let selectedTabID: UUID?

        var selectedTab: BrowserTab? {
            guard let selectedTabID else {
                return tabs.first
            }

            return tabs.first { $0.id == selectedTabID } ?? tabs.first
        }
    }

    private struct StoredSession: Codable {
        let urls: [String]
        let selectedIndex: Int
    }

    private static let defaultsKey = "Shodana.lastWindowTabs"
    private static let legacyDefaultsKeys = ["Mihako.lastWindowTabs"]
    private static var didAttemptLaunchRestore = false

    static func restoreOnceForLaunch() -> RestoredState? {
        guard !didAttemptLaunchRestore else {
            return nil
        }

        didAttemptLaunchRestore = true

        guard let data = AppDefaults.migratedData(forKey: defaultsKey, legacyKeys: legacyDefaultsKeys),
              let session = try? JSONDecoder().decode(StoredSession.self, from: data) else {
            return nil
        }

        let urls = session.urls.compactMap(restorableURL)
        guard !urls.isEmpty else {
            return nil
        }

        let tabs = urls.map(BrowserTab.init(url:))
        let selectedIndex = min(max(session.selectedIndex, 0), tabs.count - 1)

        return RestoredState(
            tabs: tabs,
            selectedTabID: tabs[selectedIndex].id
        )
    }

    static func save(tabs: [BrowserTab], selectedTabID: UUID?) {
        guard !tabs.isEmpty else {
            return
        }

        let selectedIndex = tabs.firstIndex { $0.id == selectedTabID } ?? 0
        let session = StoredSession(
            urls: tabs.map { storageString(for: $0.url) },
            selectedIndex: selectedIndex
        )

        guard let data = try? JSONEncoder().encode(session) else {
            return
        }

        AppDefaults.setCurrentAndRemoveLegacy(
            data,
            forKey: defaultsKey,
            legacyKeys: legacyDefaultsKeys
        )
    }

    private static func storageString(for url: URL) -> String {
        if url.isFileURL {
            return url.standardizedFileURL.absoluteString
        }

        return url.absoluteString
    }

    private static func restorableURL(from value: String) -> URL? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return nil
        }

        let url: URL?

        if trimmed.contains("://") {
            url = URL(string: trimmed)
        } else {
            url = URL(fileURLWithPath: (trimmed as NSString).expandingTildeInPath)
        }

        guard let url else {
            return nil
        }

        if SFTPClient.isSFTPURL(url) || S3Client.isS3URL(url) {
            return url
        }

        let fileURL = url.standardizedFileURL
        var isDirectory: ObjCBool = false

        guard FileManager.default.fileExists(atPath: fileURL.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            return nil
        }

        return fileURL
    }
}

struct BrowserTab: Identifiable, Equatable {
    let id = UUID()
    var url: URL

    var title: String {
        if SFTPClient.isSFTPURL(url) {
            return url.host(percentEncoded: false) ?? "SFTP"
        }

        if S3Client.isS3URL(url) {
            return url.host(percentEncoded: false) ?? "S3"
        }

        return url.lastPathComponent.nilIfEmpty ?? url.path
    }
}

struct BrowserTabBar: View {
    let tabs: [BrowserTab]
    let selectedTabID: UUID?
    let isDualPaneEnabled: Bool
    let onSelect: (BrowserTab) -> Void
    let onAdd: () -> Void
    let onClose: (BrowserTab) -> Void
    let onToggleDualPane: () -> Void
    let onCompareSync: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(tabs) { tab in
                        BrowserTabButton(
                            tab: tab,
                            isSelected: selectedTabID == tab.id,
                            canClose: tabs.count > 1,
                            onSelect: onSelect,
                            onClose: onClose
                        )
                    }
                }
                .padding(.vertical, 6)
            }

            ToolbarIconButton(systemImageName: "plus", help: "New Tab") {
                onAdd()
            }

            ToolbarIconButton(
                systemImageName: isDualPaneEnabled ? "rectangle.split.2x1.fill" : "rectangle.split.2x1",
                help: "Dual Pane"
            ) {
                onToggleDualPane()
            }

            ToolbarIconButton(systemImageName: "arrow.left.arrow.right", help: "Compare / Sync") {
                onCompareSync()
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 42)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

struct BrowserTabButton: View {
    let tab: BrowserTab
    let isSelected: Bool
    let canClose: Bool
    let onSelect: (BrowserTab) -> Void
    let onClose: (BrowserTab) -> Void

    var body: some View {
        HStack(spacing: 6) {
            Button {
                onSelect(tab)
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "folder")
                        .font(.caption)

                    Text(tab.title)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .frame(maxWidth: 180, alignment: .leading)
            }
            .buttonStyle(.plain)

            if canClose {
                Button {
                    onClose(tab)
                } label: {
                    Image(systemName: "xmark")
                        .font(.caption2.weight(.semibold))
                        .frame(width: 14, height: 14)
                }
                .buttonStyle(.plain)
                .help(L10n.string("Close Tab"))
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isSelected ? Color.accentColor.opacity(0.18) : Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(isSelected ? Color.accentColor.opacity(0.45) : Color.clear, lineWidth: 1)
        )
        .contentShape(Rectangle())
    }
}

struct BrowserPaneView: View {
    @EnvironmentObject private var browser: FileBrowserViewModel

    var body: some View {
        VStack(spacing: 0) {
            BrowserToolbarView()

            if browser.contentMode == .folder {
                Divider()
                BreadcrumbBar()
            }

            Divider()
            FileActionBarView()
            Divider()
            if browser.contentMode == .search && browser.searchInteractionMode == .ai {
                AISearchWorkspaceView()
            } else {
                FileListView()
            }
            Divider()
            StatusBarView()
        }
        .modifier(BrowserPresentationModifier())
    }
}

struct BrowserPresentationModifier: ViewModifier {
    @EnvironmentObject private var browser: FileBrowserViewModel

    func body(content: Content) -> some View {
        content
            .sheet(isPresented: $browser.isConnectServerDialogPresented) {
                ConnectServerSheet()
                    .environmentObject(browser)
            }
            .sheet(isPresented: $browser.isExternalToolsSettingsPresented) {
                ExternalToolsSettingsSheet()
                    .environmentObject(browser)
            }
            .sheet(isPresented: $browser.isLauncherFoldersSettingsPresented) {
                LauncherFoldersSettingsSheet()
                    .environmentObject(browser)
            }
            .sheet(isPresented: $browser.isAISearchSettingsPresented) {
                AISearchSettingsSheet()
                    .environmentObject(browser)
            }
            .sheet(item: $browser.renameRequest) { request in
                RenameSheet(
                    request: request,
                    onCommit: { newName in
                        browser.rename(url: request.url, to: newName)
                    },
                    onCancel: {
                        browser.cancelRename()
                    }
                )
            }
            .sheet(item: $browser.fileInfoRequest) { request in
                FileInfoSheet(
                    request: request,
                    onClose: {
                        browser.cancelGetInfo()
                    }
                )
            }
            .sheet(item: $browser.gitCloneRequest) { request in
                GitCloneSheet(
                    request: request,
                    onClone: { repository, destinationName in
                        browser.gitClone(
                            request: request,
                            repository: repository,
                            destinationName: destinationName
                        )
                    },
                    onCancel: {
                        browser.cancelGitClone()
                    }
                )
            }
            .sheet(item: $browser.gitCommitRequest) { request in
                GitCommitSheet(
                    request: request,
                    onCommit: { message in
                        browser.gitCommit(request: request, message: message)
                    },
                    onCancel: {
                        browser.cancelGitCommit()
                    }
                )
            }
            .sheet(item: $browser.gitBranchRequest) { request in
                GitBranchSheet(
                    request: request,
                    onSelect: { branchName in
                        browser.gitBranch(request: request, branchName: branchName)
                    },
                    onCancel: {
                        browser.cancelGitBranchRequest()
                    }
                )
            }
            .sheet(item: $browser.gitOperationResult) { result in
                GitOperationResultSheet(
                    result: result,
                    onClose: {
                        browser.clearGitOperationResult()
                    }
                )
            }
            .alert(
                browser.alertTitle,
                isPresented: Binding(
                    get: { browser.errorMessage != nil },
                    set: { isPresented in
                        if !isPresented {
                            browser.clearError()
                        }
                    }
                )
            ) {
                Button(L10n.string("OK")) {
                    browser.clearError()
                }
            } message: {
                Text(browser.errorMessage ?? "")
            }
    }
}

struct WindowReader: NSViewRepresentable {
    @Binding var window: NSWindow?

    func makeNSView(context: Context) -> NSView {
        let view = NSView()

        DispatchQueue.main.async {
            window = view.window
        }

        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        DispatchQueue.main.async {
            window = view.window
        }
    }
}

struct SidebarResizeHandle: View {
    @Binding var width: CGFloat

    let minimumWidth: CGFloat
    let maximumWidth: CGFloat

    @State private var dragStartWidth: CGFloat?
    @State private var isHovering = false
    @State private var isCursorPushed = false

    var body: some View {
        ZStack {
            Rectangle()
                .fill(Color(nsColor: .separatorColor))
                .frame(width: 1)

            Rectangle()
                .fill(isHovering ? Color.accentColor.opacity(0.22) : Color.clear)
                .frame(width: 8)
        }
        .frame(width: 8)
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    if dragStartWidth == nil {
                        dragStartWidth = width
                    }

                    let proposedWidth = (dragStartWidth ?? width) + value.translation.width
                    width = min(max(proposedWidth, minimumWidth), maximumWidth)
                }
                .onEnded { _ in
                    dragStartWidth = nil
                }
        )
        .onHover { hovering in
            isHovering = hovering

            if hovering, !isCursorPushed {
                NSCursor.resizeLeftRight.push()
                isCursorPushed = true
            } else if !hovering, isCursorPushed {
                NSCursor.pop()
                isCursorPushed = false
            }
        }
        .onDisappear {
            if isCursorPushed {
                NSCursor.pop()
                isCursorPushed = false
            }
        }
        .help(L10n.string("Resize sidebar"))
        .accessibilityLabel(L10n.string("Resize sidebar"))
    }
}

struct SidebarView: View {
    @EnvironmentObject private var browser: FileBrowserViewModel
    @State private var isFavoritesDropTargeted = false
    @State private var draggedLocationID: String?

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(browser.sidebarSections) { section in
                    SidebarLocationsSection(
                        section: section,
                        acceptsFavoriteDrops: section.title == "Favorites",
                        isDropTargeted: section.title == "Favorites" ? $isFavoritesDropTargeted : .constant(false),
                        allowsLocationReordering: section.title == "Locations",
                        draggedLocationID: $draggedLocationID
                    )
                }

                SidebarNetworkSection()
            }
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .background(Color(nsColor: .controlBackgroundColor))
    }
}

struct SidebarLocationsSection: View {
    @EnvironmentObject private var browser: FileBrowserViewModel

    let section: SidebarSection
    let acceptsFavoriteDrops: Bool
    @Binding var isDropTargeted: Bool
    let allowsLocationReordering: Bool
    @Binding var draggedLocationID: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(L10n.string(section.title))
                .font(.caption.weight(.semibold))
                .foregroundStyle(isDropTargeted ? Color.accentColor : .secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.top, 8)
                .padding(.bottom, 3)
                .contentShape(Rectangle())
                .modifier(
                    FavoriteDropTargetModifier(
                        isEnabled: acceptsFavoriteDrops,
                        isTargeted: $isDropTargeted
                    )
                )

            ForEach(section.locations) { location in
                SidebarLocationRow(location: location)
                    .modifier(
                        FavoriteDropTargetModifier(
                            isEnabled: acceptsFavoriteDrops,
                            isTargeted: $isDropTargeted
                        )
                    )
                    .modifier(
                        LocationReorderModifier(
                            isEnabled: allowsLocationReordering,
                            location: location,
                            draggedLocationID: $draggedLocationID
                        )
                    )
            }

            if allowsLocationReordering {
                Color.clear
                    .frame(height: 10)
                    .contentShape(Rectangle())
                    .onDrop(
                        of: [UTType.plainText.identifier],
                        delegate: LocationReorderEndDropDelegate(
                            browser: browser,
                            draggedLocationID: $draggedLocationID
                        )
                    )
            }
        }
        .padding(.bottom, 4)
        .background {
            if acceptsFavoriteDrops {
                FavoritesDropTargetView(isTargeted: $isDropTargeted)
                    .environmentObject(browser)
            }
        }
        .modifier(
            FavoriteDropTargetModifier(
                isEnabled: acceptsFavoriteDrops,
                isTargeted: $isDropTargeted
            )
        )
    }
}

struct LocationReorderModifier: ViewModifier {
    let isEnabled: Bool
    let location: SidebarLocation
    @Binding var draggedLocationID: String?

    @ViewBuilder
    func body(content: Content) -> some View {
        if isEnabled {
            content
                .onDrag {
                    draggedLocationID = location.id
                    return NSItemProvider(object: location.id as NSString)
                }
                .onDrop(
                    of: [UTType.plainText.identifier],
                    delegate: LocationReorderDropDelegate(
                        browser: browser,
                        location: location,
                        draggedLocationID: $draggedLocationID
                    )
                )
        } else {
            content
        }
    }

    @EnvironmentObject private var browser: FileBrowserViewModel
}

struct LocationReorderDropDelegate: DropDelegate {
    let browser: FileBrowserViewModel
    let location: SidebarLocation
    @Binding var draggedLocationID: String?

    func validateDrop(info: DropInfo) -> Bool {
        draggedLocationID != nil
    }

    func dropEntered(info: DropInfo) {
        guard let sourceID = draggedLocationID,
              sourceID != location.id else {
            return
        }

        browser.moveSidebarLocation(sourceID: sourceID, over: location.id)
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        draggedLocationID = nil
        return true
    }
}

struct LocationReorderEndDropDelegate: DropDelegate {
    let browser: FileBrowserViewModel
    @Binding var draggedLocationID: String?

    func validateDrop(info: DropInfo) -> Bool {
        draggedLocationID != nil
    }

    func dropEntered(info: DropInfo) {
        guard let sourceID = draggedLocationID else {
            return
        }

        browser.moveSidebarLocationToEnd(sourceID: sourceID)
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        if let sourceID = draggedLocationID {
            browser.moveSidebarLocationToEnd(sourceID: sourceID)
        }

        draggedLocationID = nil
        return true
    }
}

struct FavoriteDropTargetModifier: ViewModifier {
    @EnvironmentObject private var browser: FileBrowserViewModel

    let isEnabled: Bool
    @Binding var isTargeted: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if isEnabled {
            content.onDrop(
                of: [UTType.fileURL.identifier, UTType.url.identifier, UTType.plainText.identifier],
                isTargeted: $isTargeted
            ) { providers in
                browser.addFavoriteFolders(from: providers)
            }
        } else {
            content
        }
    }
}

struct SidebarNetworkSection: View {
    @EnvironmentObject private var browser: FileBrowserViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(L10n.string("Network"))
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.top, 8)
                .padding(.bottom, 3)

            Button {
                browser.promptConnectToServer()
            } label: {
                Label(L10n.string("Connect..."), systemImage: "network")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 12)
            .padding(.vertical, 4)

            Button {
                browser.reloadLocations()
            } label: {
                Label(L10n.string("Reload Locations"), systemImage: "arrow.clockwise")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
            .help(L10n.string("Rescan cloud folders, mounted drives, and network volumes"))
        }
        .padding(.bottom, 4)
    }
}

struct SidebarLocationRow: View {
    @EnvironmentObject private var browser: FileBrowserViewModel

    let location: SidebarLocation

    var body: some View {
        Button {
            browser.open(location)
        } label: {
            Label {
                Text(L10n.string(location.title))
            } icon: {
                Image(systemName: location.systemImageName)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .contextMenu {
            LocationContextMenu(location: location)
        }
    }
}

struct AISearchSettingsSheet: View {
    @EnvironmentObject private var browser: FileBrowserViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var settings: AISearchSettings = .defaultSettings
    @State private var apiKey = ""
    @State private var selectedScopeID: UUID?

    private var selectedScopeIndex: Int? {
        guard let selectedScopeID else {
            return nil
        }

        return settings.scopes.firstIndex { $0.id == selectedScopeID }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(L10n.string("AI Search Settings"))
                .font(.title3.weight(.semibold))

            HStack(alignment: .top, spacing: 14) {
                scopeList

                Divider()
                    .frame(height: 430)

                VStack(alignment: .leading, spacing: 12) {
                    providerSettings

                    Divider()

                    limitsSettings

                    Divider()

                    excludeSettings
                }
                .frame(width: 470, alignment: .topLeading)
            }

            HStack {
                Button(L10n.string("Restore Defaults")) {
                    let scopes = settings.scopes
                    settings = .defaultSettings
                    settings.scopes = scopes
                }

                Spacer()

                Button(L10n.string("Cancel")) {
                    dismiss()
                }

                Button(L10n.string("Save")) {
                    browser.saveAISearchSettings(settings, apiKey: apiKey)
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 840)
        .onAppear {
            settings = browser.aiSearchSettings
            apiKey = browser.aiProviderAPIKey
            selectedScopeID = settings.scopes.first?.id
        }
    }

    private var scopeList: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L10n.string("Allowed AI Scope"))
                .font(.headline)

            ScrollView {
                LazyVStack(spacing: 4) {
                    ForEach(settings.scopes) { scope in
                        Button {
                            selectedScopeID = scope.id
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(scope.title)
                                    .lineLimit(1)

                                Text(scope.path)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 6)
                            .background(
                                RoundedRectangle(cornerRadius: 6)
                                    .fill(selectedScopeID == scope.id ? Color.accentColor.opacity(0.18) : Color.clear)
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .frame(width: 280, height: 270)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color(nsColor: .controlBackgroundColor))
            )

            HStack(spacing: 6) {
                ToolbarIconButton(systemImageName: "plus", help: "Add Folder") {
                    addScope()
                }

                ToolbarIconButton(systemImageName: "arrow.up", help: "Move Up") {
                    moveSelectedScope(offset: -1)
                }
                .disabled(selectedScopeIndex == nil || selectedScopeIndex == 0)

                ToolbarIconButton(systemImageName: "arrow.down", help: "Move Down") {
                    moveSelectedScope(offset: 1)
                }
                .disabled(selectedScopeIndex == nil || selectedScopeIndex == settings.scopes.count - 1)

                ToolbarIconButton(systemImageName: "trash", help: "Delete") {
                    deleteSelectedScope()
                }
                .disabled(selectedScopeIndex == nil)
            }

            if let selectedScopeIndex {
                VStack(alignment: .leading, spacing: 8) {
                    TextField(L10n.string("Name"), text: $settings.scopes[selectedScopeIndex].title)
                        .textFieldStyle(.roundedBorder)

                    TextField(L10n.string("Folder path"), text: $settings.scopes[selectedScopeIndex].path)
                        .textFieldStyle(.roundedBorder)

                    Button(L10n.string("Choose Folder...")) {
                        chooseFolder(for: selectedScopeIndex)
                    }
                }
            } else {
                Text(L10n.string("Add folders that may be disclosed to AI."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var providerSettings: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L10n.string("AI Provider"))
                .font(.headline)

            LabeledContent(L10n.string("Endpoint")) {
                TextField("https://api.example.com/v1/chat/completions", text: $settings.endpointURLString)
                    .textFieldStyle(.roundedBorder)
            }

            LabeledContent(L10n.string("Model")) {
                TextField("model-name", text: $settings.model)
                    .textFieldStyle(.roundedBorder)
            }

            LabeledContent(L10n.string("API Key")) {
                SecureField("sk-...", text: $apiKey)
                    .textFieldStyle(.roundedBorder)
            }

            Text(L10n.string("Use an OpenAI-compatible Chat Completions endpoint. The API key is stored in macOS Keychain."))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var limitsSettings: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L10n.string("Context Limits"))
                .font(.headline)

            HStack {
                LabeledContent(L10n.string("Files")) {
                    TextField("", value: $settings.maxFiles, format: .number)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 76)
                }

                LabeledContent(L10n.string("File bytes")) {
                    TextField("", value: $settings.maxFileBytes, format: .number)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 96)
                }

                LabeledContent(L10n.string("Context chars")) {
                    TextField("", value: $settings.maxContextCharacters, format: .number)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 105)
                }
            }
        }
    }

    private var excludeSettings: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L10n.string("Exclude Patterns"))
                .font(.headline)

            TextEditor(text: $settings.excludedPatternsText)
                .font(.system(size: 12, design: .monospaced))
                .frame(height: 120)
                .background(Color(nsColor: .textBackgroundColor))

            Text(L10n.string("One pattern per line. Secrets such as .env and key files are excluded by default."))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func addScope() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false

        guard panel.runModal() == .OK, let url = panel.url else {
            return
        }

        let normalizedURL = url.standardizedFileURL
        let scope = AIStorageScope(
            title: FileManager.default.displayName(atPath: normalizedURL.path).nilIfEmpty
                ?? normalizedURL.lastPathComponent,
            path: normalizedURL.path
        )
        settings.scopes.append(scope)
        selectedScopeID = scope.id
    }

    private func chooseFolder(for index: Int) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false

        let currentPath = settings.scopes[index].path
        if FileManager.default.fileExists(atPath: currentPath) {
            panel.directoryURL = URL(fileURLWithPath: currentPath, isDirectory: true)
        }

        guard panel.runModal() == .OK, let url = panel.url else {
            return
        }

        let normalizedURL = url.standardizedFileURL
        settings.scopes[index].path = normalizedURL.path

        if settings.scopes[index].title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            settings.scopes[index].title = FileManager.default.displayName(atPath: normalizedURL.path).nilIfEmpty
                ?? normalizedURL.lastPathComponent
        }
    }

    private func deleteSelectedScope() {
        guard let selectedScopeIndex else {
            return
        }

        settings.scopes.remove(at: selectedScopeIndex)
        selectedScopeID = settings.scopes.indices.contains(selectedScopeIndex)
            ? settings.scopes[selectedScopeIndex].id
            : settings.scopes.last?.id
    }

    private func moveSelectedScope(offset: Int) {
        guard let selectedScopeIndex else {
            return
        }

        let destinationIndex = selectedScopeIndex + offset
        guard settings.scopes.indices.contains(destinationIndex) else {
            return
        }

        settings.scopes.swapAt(selectedScopeIndex, destinationIndex)
    }
}

struct BrowserToolbarView: View {
    @EnvironmentObject private var browser: FileBrowserViewModel

    var body: some View {
        HStack(spacing: 8) {
            Picker(L10n.string("Content mode"), selection: $browser.contentMode) {
                Image(systemName: "folder")
                    .tag(BrowserContentMode.folder)

                Image(systemName: "magnifyingglass")
                    .tag(BrowserContentMode.search)
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .frame(width: 88)
            .help(L10n.string("Folder or search results"))

            if browser.contentMode == .folder {
                FolderToolbarControls()
            } else {
                SearchToolbarControls()
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}

struct FolderToolbarControls: View {
    @EnvironmentObject private var browser: FileBrowserViewModel

    var body: some View {
        ToolbarIconButton(systemImageName: "chevron.left", help: "Back") {
            browser.goBack()
        }
        .disabled(!browser.canGoBack)

        ToolbarIconButton(systemImageName: "chevron.right", help: "Forward") {
            browser.goForward()
        }
        .disabled(!browser.canGoForward)

        ToolbarIconButton(systemImageName: "arrow.up", help: "Up") {
            browser.goUp()
        }
        .disabled(!browser.canGoUp)

        ToolbarIconButton(systemImageName: "arrow.clockwise", help: "Reload") {
            browser.reload()
        }

        TextField(L10n.string("Path"), text: $browser.addressText)
            .textFieldStyle(.roundedBorder)
            .font(.system(size: NSFont.systemFontSize, design: .monospaced))
            .lineLimit(1)
            .onSubmit {
                browser.submitAddress()
            }
            .help(L10n.string("Path"))
            .frame(maxWidth: .infinity)
            .frame(height: 24)
            .layoutPriority(1)

        Button {
            browser.submitAddress()
        } label: {
            Image(systemName: "arrow.right.circle")
        }
        .help(L10n.string("Go"))

        Toggle(isOn: $browser.showHiddenFiles) {
            Image(systemName: browser.showHiddenFiles ? "eye" : "eye.slash")
        }
        .toggleStyle(.button)
        .help(L10n.string("Show hidden files"))
    }
}

struct SearchToolbarControls: View {
    @EnvironmentObject private var browser: FileBrowserViewModel

    var body: some View {
        Picker(L10n.string("Search Type"), selection: $browser.searchInteractionMode) {
            ForEach(SearchInteractionMode.allCases) { mode in
                Image(systemName: mode.systemImageName)
                    .tag(mode)
                    .help(L10n.string(mode.titleKey))
            }
        }
        .labelsHidden()
        .pickerStyle(.segmented)
        .frame(width: 88)
        .help(L10n.string("Search Type"))

        TextField(L10n.string("Path"), text: $browser.addressText)
            .textFieldStyle(.roundedBorder)
            .font(.system(size: NSFont.systemFontSize, design: .monospaced))
            .lineLimit(1)
            .onSubmit {
                browser.performSearch()
            }
            .help(browser.searchInteractionMode == .ai ? L10n.string("AI Search Path") : L10n.string("Search Path"))
            .frame(minWidth: 220, maxWidth: .infinity)
            .frame(height: 24)
            .layoutPriority(1)

        TextField(
            browser.searchInteractionMode == .ai ? L10n.string("Ask about files") : L10n.string("Search"),
            text: $browser.searchText
        )
            .textFieldStyle(.roundedBorder)
            .lineLimit(1)
            .onSubmit {
                browser.performSearch()
            }
            .help(browser.searchInteractionMode == .ai ? L10n.string("Ask AI about files below path") : L10n.string("Search below path"))
            .frame(minWidth: 180, maxWidth: .infinity)
            .frame(height: 24)
            .layoutPriority(2)

        Button {
            browser.performSearch()
        } label: {
            Image(systemName: browser.searchInteractionMode == .ai ? "sparkles" : "magnifyingglass.circle")
        }
        .disabled(browser.searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || browser.isSearching || browser.isAIThinking)
        .help(browser.searchInteractionMode == .ai ? L10n.string("Ask AI") : L10n.string("Search"))

        if browser.searchInteractionMode == .ai {
            ToolbarIconButton(systemImageName: "folder.badge.gearshape", help: "Add Current Path to AI Scope") {
                browser.addCurrentPathToAIScope()
            }

            ToolbarIconButton(systemImageName: "gearshape", help: "AI Search Settings") {
                browser.showAISearchSettings()
            }
        }

        if browser.isSearching || browser.isAIThinking {
            ProgressView()
                .controlSize(.small)

            ToolbarIconButton(systemImageName: "xmark.circle.fill", help: "Stop Search") {
                browser.cancelSearch()
            }
        }
    }
}

struct ToolbarIconButton: View {
    let systemImageName: String
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImageName)
                .frame(width: 18, height: 18)
        }
        .buttonStyle(.bordered)
        .controlSize(.regular)
        .help(L10n.string(help))
    }
}

struct AISearchWorkspaceView: View {
    @EnvironmentObject private var browser: FileBrowserViewModel

    var body: some View {
        HStack(spacing: 0) {
            aiContextPane
                .frame(minWidth: 320, idealWidth: 390, maxWidth: 460)

            Divider()

            aiConversationPane
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Color(nsColor: .textBackgroundColor))
    }

    private var aiContextPane: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Label(L10n.string("AI Context"), systemImage: "doc.text.magnifyingglass")
                    .font(.headline)

                Spacer()

                Button {
                    browser.showAISearchSettings()
                } label: {
                    Image(systemName: "gearshape")
                }
                .buttonStyle(.bordered)
                .help(L10n.string("AI Search Settings"))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)

            if !browser.aiContextSummary.isEmpty {
                Text(browser.aiContextSummary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 8)
            }

            Divider()

            if browser.aiContextFiles.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "folder.badge.questionmark")
                        .font(.system(size: 28))
                        .foregroundStyle(.secondary)

                    Text(L10n.string("No AI context files yet."))
                        .foregroundStyle(.secondary)

                    Button(L10n.string("Add Current Path to AI Scope")) {
                        browser.addCurrentPathToAIScope()
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(20)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(browser.aiContextFiles) { file in
                            AIContextFileRow(file: file)
                        }
                    }
                    .padding(10)
                }
            }
        }
    }

    private var aiConversationPane: some View {
        VStack(spacing: 0) {
            HStack {
                Label(L10n.string("AI Conversation"), systemImage: "sparkles")
                    .font(.headline)

                Spacer()

                Button(L10n.string("Clear")) {
                    browser.clearAIConversation()
                }
                .disabled(browser.aiChatMessages.isEmpty && browser.aiContextFiles.isEmpty)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)

            Divider()

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    if browser.aiChatMessages.isEmpty {
                        VStack(spacing: 10) {
                            Image(systemName: "sparkles")
                                .font(.system(size: 28))
                                .foregroundStyle(.secondary)

                            Text(L10n.string("Ask about files in the allowed AI scope."))
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, minHeight: 220)
                    } else {
                        ForEach(browser.aiChatMessages) { message in
                            AIChatMessageBubble(message: message)
                                .frame(maxWidth: .infinity)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(14)
            }
            .frame(maxWidth: .infinity)

            Divider()

            HStack(spacing: 8) {
                TextField(L10n.string("Ask about files"), text: $browser.searchText)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit {
                        browser.performAISearch()
                    }

                Button {
                    browser.performAISearch()
                } label: {
                    Image(systemName: "paperplane.fill")
                }
                .disabled(browser.searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || browser.isAIThinking)

                if browser.isAIThinking {
                    ProgressView()
                        .controlSize(.small)
                }
            }
            .padding(12)
        }
    }
}

struct AIContextFileRow: View {
    @EnvironmentObject private var browser: FileBrowserViewModel

    let file: AIContextFile

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: file.url.path))
                    .resizable()
                    .frame(width: 18, height: 18)

                VStack(alignment: .leading, spacing: 2) {
                    Text(file.relativePath)
                        .font(.system(size: 12, weight: .semibold))
                        .lineLimit(1)
                        .truncationMode(.middle)

                    Text(file.matchSummary)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer()

                Button {
                    browser.openAIContextFile(file)
                } label: {
                    Image(systemName: "arrow.up.forward.app")
                }
                .buttonStyle(.borderless)
                .help(L10n.string("Open"))
            }

            Text(file.snippet)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(4)
                .textSelection(.enabled)
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
    }
}

struct AIChatMessageBubble: View {
    let message: AIChatMessage

    private var isUserMessage: Bool {
        message.role == .user
    }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            if isUserMessage {
                Spacer(minLength: 96)
            }

            bubble
                .frame(
                    maxWidth: isUserMessage ? 560 : .infinity,
                    alignment: .leading
                )

            if !isUserMessage {
                Spacer(minLength: 64)
            }
        }
        .frame(maxWidth: .infinity, alignment: isUserMessage ? .trailing : .leading)
    }

    private var bubble: some View {
        VStack(alignment: isUserMessage ? .trailing : .leading, spacing: 6) {
            Text(L10n.string(message.role.titleKey))
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: isUserMessage ? .trailing : .leading)

            Text(message.content)
                .textSelection(.enabled)
                .font(.system(size: 13))
                .multilineTextAlignment(isUserMessage ? .trailing : .leading)
                .frame(maxWidth: .infinity, alignment: isUserMessage ? .trailing : .leading)
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 7)
                .fill(isUserMessage ? Color.accentColor.opacity(0.16) : Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 7)
                .stroke(
                    isUserMessage ? Color.accentColor.opacity(0.12) : Color(nsColor: .separatorColor).opacity(0.45),
                    lineWidth: 1
                )
        )
    }
}

struct BreadcrumbBar: View {
    @EnvironmentObject private var browser: FileBrowserViewModel

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                ForEach(Array(browser.breadcrumbs.enumerated()), id: \.element.id) { index, crumb in
                    Button {
                        browser.navigate(to: crumb.url)
                    } label: {
                        Text(crumb.title)
                            .lineLimit(1)
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(
                        RoundedRectangle(cornerRadius: 5)
                            .fill(Color(nsColor: .controlBackgroundColor))
                    )

                    if index < browser.breadcrumbs.count - 1 {
                        Image(systemName: "chevron.right")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
        }
        .frame(height: 38)
    }
}

struct FileActionBarView: View {
    @EnvironmentObject private var browser: FileBrowserViewModel

    var body: some View {
        HStack(spacing: 8) {
            Picker(L10n.string("View"), selection: $browser.viewMode) {
                Image(systemName: "list.bullet")
                    .tag(BrowserViewMode.list)

                Image(systemName: "square.grid.2x2")
                    .tag(BrowserViewMode.icons)

                Image(systemName: "rectangle.split.3x1")
                    .tag(BrowserViewMode.columns)

                Image(systemName: "rectangle.on.rectangle")
                    .tag(BrowserViewMode.gallery)
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .frame(width: 184)
            .help(L10n.string("View mode"))

            FileGroupMenuButton()

            Divider()
                .frame(height: 22)

            ToolbarIconButton(systemImageName: "square.and.arrow.down", help: "Clone Repository") {
                browser.beginGitClone()
            }
            .disabled(!browser.canCloneRepository)

            ToolbarIconButton(systemImageName: "plus.circle", help: "Git Add Selected") {
                browser.gitAddSelection()
            }
            .disabled(!browser.canGitAddSelection)

            ToolbarIconButton(systemImageName: "checkmark.circle", help: "Git Commit Selected...") {
                browser.beginGitCommitSelection()
            }
            .disabled(!browser.canGitCommitSelection)

            ToolbarIconButton(systemImageName: "arrow.down.circle", help: "Git Pull") {
                browser.gitPull()
            }
            .disabled(!browser.canUseGit)

            ToolbarIconButton(systemImageName: "arrow.up.circle", help: "Git Push") {
                browser.gitPush()
            }
            .disabled(!browser.canUseGit)

            ToolbarIconButton(systemImageName: "arrow.triangle.merge", help: "Merge Branch...") {
                browser.beginGitMergeBranch()
            }
            .disabled(!browser.canUseGit)

            Divider()
                .frame(height: 22)

            ToolbarIconButton(systemImageName: "folder.badge.plus", help: "New Folder") {
                browser.createFolder()
            }

            ToolbarIconButton(systemImageName: "doc.badge.plus", help: "New File") {
                browser.createFile()
            }

            ToolbarIconButton(systemImageName: "trash", help: "Move to Trash") {
                browser.trashSelection()
            }
            .disabled(browser.selectedIDs.isEmpty)

            Divider()
                .frame(height: 22)

            ToolbarIconButton(systemImageName: "dot.radiowaves.left.and.right", help: "AirDrop") {
                browser.shareSelectionViaAirDrop()
            }
            .disabled(browser.selectedIDs.isEmpty)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(browser.externalTools) { tool in
                        ExternalToolToolbarButton(tool: tool)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            ToolbarIconButton(systemImageName: "gearshape", help: "Configure External Tools") {
                browser.showExternalToolsSettings()
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .frame(height: 42)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

struct FileGroupMenuButton: View {
    @EnvironmentObject private var browser: FileBrowserViewModel

    var body: some View {
        Menu {
            ForEach(FileGroupMode.allCases) { mode in
                Button {
                    browser.groupMode = mode
                } label: {
                    HStack {
                        Text(L10n.string(mode.titleKey))

                        if browser.groupMode == mode {
                            Image(systemName: "checkmark")
                        }
                    }
                }
            }
        } label: {
            Image(systemName: browser.groupMode == .none ? "square.grid.3x3" : "square.grid.3x3.fill")
                .frame(width: 18, height: 18)
        }
        .menuStyle(.button)
        .buttonStyle(.bordered)
        .controlSize(.regular)
        .help(groupHelpText)
    }

    private var groupHelpText: String {
        browser.groupMode == .none
            ? L10n.string("Group")
            : String(format: L10n.string("Grouped by %@"), L10n.string(browser.groupMode.titleKey))
    }
}

struct ExternalToolToolbarButton: View {
    @EnvironmentObject private var browser: FileBrowserViewModel

    let tool: ExternalTool

    var body: some View {
        Button {
            browser.openExternalTool(tool)
        } label: {
            ExternalToolIconView(tool: tool, size: 18) {
                browser.applicationIcon(for: tool)
            }
        }
        .buttonStyle(.bordered)
        .controlSize(.regular)
        .help(String(format: L10n.string("Open with %@"), tool.title))
        .disabled(!browser.canOpenExternalTool(tool))
    }
}

struct ExternalToolIconView: View {
    let tool: ExternalTool
    let size: CGFloat
    let applicationIcon: () -> NSImage?

    var body: some View {
        if let icon = applicationIcon() {
            Image(nsImage: icon)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: size, height: size)
        } else {
            Image(systemName: tool.systemImageName)
                .frame(width: size, height: size)
        }
    }
}

struct LauncherFoldersSettingsSheet: View {
    @EnvironmentObject private var browser: FileBrowserViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var shortcuts: [LauncherFolderShortcut] = []
    @State private var selectedShortcutID: UUID?

    private var selectedIndex: Int? {
        guard let selectedShortcutID else {
            return nil
        }

        return shortcuts.firstIndex { $0.id == selectedShortcutID }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(L10n.string("Launcher Folders"))
                .font(.title3.weight(.semibold))

            HStack(alignment: .top, spacing: 14) {
                VStack(spacing: 8) {
                    ScrollView {
                        LazyVStack(spacing: 4) {
                            ForEach(shortcuts) { shortcut in
                                Button {
                                    selectedShortcutID = shortcut.id
                                } label: {
                                    HStack(spacing: 8) {
                                        Image(systemName: "folder")
                                            .frame(width: 18, height: 18)

                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(shortcut.title)
                                                .lineLimit(1)

                                            Text(shortcut.path)
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                                .lineLimit(1)
                                                .truncationMode(.middle)
                                        }

                                        Spacer()
                                    }
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 6)
                                    .background(
                                        RoundedRectangle(cornerRadius: 6)
                                            .fill(selectedShortcutID == shortcut.id ? Color.accentColor.opacity(0.18) : Color.clear)
                                    )
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    .frame(width: 260, height: 280)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(Color(nsColor: .controlBackgroundColor))
                    )

                    HStack(spacing: 6) {
                        ToolbarIconButton(systemImageName: "plus", help: "Add Folder Shortcut") {
                            addFolderShortcut()
                        }

                        ToolbarIconButton(systemImageName: "arrow.up", help: "Move Up") {
                            moveSelectedShortcut(offset: -1)
                        }
                        .disabled(selectedIndex == nil || selectedIndex == 0)

                        ToolbarIconButton(systemImageName: "arrow.down", help: "Move Down") {
                            moveSelectedShortcut(offset: 1)
                        }
                        .disabled(selectedIndex == nil || selectedIndex == shortcuts.count - 1)

                        ToolbarIconButton(systemImageName: "trash", help: "Delete Shortcut") {
                            deleteSelectedShortcut()
                        }
                        .disabled(selectedIndex == nil)
                    }
                }

                Divider()
                    .frame(height: 325)

                if let selectedIndex {
                    LauncherFolderShortcutEditorView(shortcut: $shortcuts[selectedIndex])
                        .frame(width: 390, alignment: .topLeading)
                } else {
                    Text(L10n.string("Select a folder shortcut to edit."))
                        .foregroundStyle(.secondary)
                        .frame(width: 390, height: 280, alignment: .center)
                }
            }

            HStack {
                Spacer()

                Button(L10n.string("Cancel")) {
                    dismiss()
                }

                Button(L10n.string("Save")) {
                    browser.saveLauncherFolderShortcuts(shortcuts)
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 720)
        .onAppear {
            shortcuts = browser.launcherFolderShortcuts
            selectedShortcutID = shortcuts.first?.id
        }
    }

    private func addFolderShortcut() {
        let folderURL = FileManager.default.homeDirectoryForCurrentUser
        let shortcut = LauncherFolderShortcut(
            title: L10n.string("New Folder Shortcut"),
            path: folderURL.path
        )
        shortcuts.append(shortcut)
        selectedShortcutID = shortcut.id
    }

    private func deleteSelectedShortcut() {
        guard let selectedIndex else {
            return
        }

        shortcuts.remove(at: selectedIndex)
        selectedShortcutID = shortcuts.indices.contains(selectedIndex)
            ? shortcuts[selectedIndex].id
            : shortcuts.last?.id
    }

    private func moveSelectedShortcut(offset: Int) {
        guard let selectedIndex else {
            return
        }

        let destinationIndex = selectedIndex + offset
        guard shortcuts.indices.contains(destinationIndex) else {
            return
        }

        shortcuts.swapAt(selectedIndex, destinationIndex)
    }
}

struct LauncherFolderShortcutEditorView: View {
    @Binding var shortcut: LauncherFolderShortcut

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            LabeledContent(L10n.string("Name")) {
                TextField(L10n.string("Name"), text: $shortcut.title)
                    .textFieldStyle(.roundedBorder)
            }

            LabeledContent(L10n.string("Folder path")) {
                TextField("/Users/name/Folder", text: $shortcut.path)
                    .textFieldStyle(.roundedBorder)
            }

            Button(L10n.string("Choose Folder...")) {
                chooseFolder()
            }
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false

        if FileManager.default.fileExists(atPath: shortcut.path) {
            panel.directoryURL = URL(fileURLWithPath: shortcut.path, isDirectory: true)
        }

        guard panel.runModal() == .OK, let url = panel.url else {
            return
        }

        shortcut.path = url.standardizedFileURL.path

        if shortcut.title == L10n.string("New Folder Shortcut")
            || shortcut.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            shortcut.title = FileManager.default.displayName(atPath: url.path).nilIfEmpty
                ?? url.lastPathComponent
        }
    }
}

struct ExternalToolsSettingsSheet: View {
    @EnvironmentObject private var browser: FileBrowserViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var tools: [ExternalTool] = []
    @State private var selectedToolID: UUID?

    private var selectedIndex: Int? {
        guard let selectedToolID else {
            return nil
        }

        return tools.firstIndex { $0.id == selectedToolID }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(L10n.string("External Tools"))
                .font(.title3.weight(.semibold))

            HStack(alignment: .top, spacing: 14) {
                VStack(spacing: 8) {
                    ScrollView {
                        LazyVStack(spacing: 4) {
                            ForEach(tools) { tool in
                                Button {
                                    selectedToolID = tool.id
                                } label: {
                                    HStack(spacing: 8) {
                                        ExternalToolIconView(tool: tool, size: 18) {
                                            applicationIcon(for: tool)
                                        }

                                        Text(tool.title)
                                            .lineLimit(1)

                                        Spacer()
                                    }
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 6)
                                    .background(
                                        RoundedRectangle(cornerRadius: 6)
                                            .fill(selectedToolID == tool.id ? Color.accentColor.opacity(0.18) : Color.clear)
                                    )
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    .frame(width: 220, height: 310)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(Color(nsColor: .controlBackgroundColor))
                    )

                    HStack(spacing: 6) {
                        ToolbarIconButton(systemImageName: "plus", help: "Add Application Tool") {
                            addApplicationTool()
                        }

                        ToolbarIconButton(systemImageName: "terminal", help: "Add Terminal Tool") {
                            addTerminalTool()
                        }

                        ToolbarIconButton(systemImageName: "arrow.up", help: "Move Up") {
                            moveSelectedTool(offset: -1)
                        }
                        .disabled(selectedIndex == nil || selectedIndex == 0)

                        ToolbarIconButton(systemImageName: "arrow.down", help: "Move Down") {
                            moveSelectedTool(offset: 1)
                        }
                        .disabled(selectedIndex == nil || selectedIndex == tools.count - 1)

                        ToolbarIconButton(systemImageName: "trash", help: "Delete Tool") {
                            deleteSelectedTool()
                        }
                        .disabled(selectedIndex == nil)
                    }
                }

                Divider()
                    .frame(height: 350)

                if let selectedIndex {
                    ExternalToolEditorView(tool: $tools[selectedIndex])
                        .frame(width: 390, alignment: .topLeading)
                } else {
                    Text(L10n.string("Select a tool to edit."))
                        .foregroundStyle(.secondary)
                        .frame(width: 390, height: 320, alignment: .center)
                }
            }

            HStack {
                Button(L10n.string("Restore Defaults")) {
                    tools = ExternalTool.defaultTools
                    selectedToolID = tools.first?.id
                }

                Spacer()

                Button(L10n.string("Cancel")) {
                    dismiss()
                }

                Button(L10n.string("Save")) {
                    browser.saveExternalTools(tools)
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 690)
        .onAppear {
            tools = browser.externalTools
            selectedToolID = tools.first?.id
        }
    }

    private func addApplicationTool() {
        let tool = ExternalTool(
            title: L10n.string("New Tool"),
            systemImageName: "app",
            iconMode: .applicationIcon,
            kind: .application,
            target: .selectedFolder
        )
        tools.append(tool)
        selectedToolID = tool.id
    }

    private func addTerminalTool() {
        let tool = ExternalTool(
            title: "Terminal",
            systemImageName: "terminal",
            iconMode: .applicationIcon,
            kind: .terminal,
            target: .currentFolder
        )
        tools.append(tool)
        selectedToolID = tool.id
    }

    private func deleteSelectedTool() {
        guard let selectedIndex else {
            return
        }

        tools.remove(at: selectedIndex)
        selectedToolID = tools.indices.contains(selectedIndex)
            ? tools[selectedIndex].id
            : tools.last?.id
    }

    private func moveSelectedTool(offset: Int) {
        guard let selectedIndex else {
            return
        }

        let destinationIndex = selectedIndex + offset
        guard tools.indices.contains(destinationIndex) else {
            return
        }

        tools.swapAt(selectedIndex, destinationIndex)
    }

    private func applicationIcon(for tool: ExternalTool) -> NSImage? {
        guard tool.iconMode == .applicationIcon else {
            return nil
        }

        if let applicationPath = tool.applicationPath,
           FileManager.default.fileExists(atPath: applicationPath) {
            return NSWorkspace.shared.icon(forFile: applicationPath)
        }

        switch tool.kind {
        case .terminal:
            let terminalURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Terminal")
                ?? URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app")
            return NSWorkspace.shared.icon(forFile: terminalURL.path)
        case .iTerm:
            if let iTermURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.googlecode.iterm2") {
                return NSWorkspace.shared.icon(forFile: iTermURL.path)
            }
        case .application:
            break
        }

        for bundleIdentifier in tool.bundleIdentifiers {
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) {
                return NSWorkspace.shared.icon(forFile: url.path)
            }
        }

        return nil
    }
}

struct ExternalToolEditorView: View {
    @Binding var tool: ExternalTool

    private var bundleIdentifiersText: Binding<String> {
        Binding(
            get: {
                tool.bundleIdentifiers.joined(separator: ", ")
            },
            set: { newValue in
                tool.bundleIdentifiers = newValue
                    .split { character in
                        character == "," || character == " " || character == "\n"
                    }
                    .map(String.init)
            }
        )
    }

    private var applicationPathText: Binding<String> {
        Binding(
            get: {
                tool.applicationPath ?? ""
            },
            set: { newValue in
                tool.applicationPath = newValue.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
            }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            LabeledContent(L10n.string("Name")) {
                TextField(L10n.string("Name"), text: $tool.title)
                    .textFieldStyle(.roundedBorder)
            }

            LabeledContent(L10n.string("Tool Type")) {
                Picker(L10n.string("Tool Type"), selection: $tool.kind) {
                    ForEach(ExternalToolKind.allCases) { kind in
                        Text(L10n.string(kind.titleKey)).tag(kind)
                    }
                }
                .labelsHidden()
                .frame(maxWidth: .infinity)
            }

            LabeledContent(L10n.string("Open Target")) {
                Picker(L10n.string("Open Target"), selection: $tool.target) {
                    ForEach(ExternalToolTarget.allCases) { target in
                        Text(L10n.string(target.titleKey)).tag(target)
                    }
                }
                .labelsHidden()
                .frame(maxWidth: .infinity)
            }

            LabeledContent(L10n.string("Icon")) {
                Picker(L10n.string("Icon"), selection: $tool.iconMode) {
                    ForEach(ExternalToolIconMode.allCases) { mode in
                        Text(L10n.string(mode.titleKey)).tag(mode)
                    }
                }
                .labelsHidden()
                .frame(maxWidth: .infinity)
            }

            LabeledContent(L10n.string("SF Symbol")) {
                TextField(L10n.string("SF Symbol"), text: $tool.systemImageName)
                    .textFieldStyle(.roundedBorder)
            }

            if tool.kind == .application {
                LabeledContent(L10n.string("Bundle identifiers")) {
                    TextField("com.example.App", text: bundleIdentifiersText)
                        .textFieldStyle(.roundedBorder)
                }

                LabeledContent(L10n.string("Application path")) {
                    TextField("/Applications/App.app", text: applicationPathText)
                        .textFieldStyle(.roundedBorder)
                }

                Button(L10n.string("Choose Application...")) {
                    chooseApplication()
                }
            }
        }
    }

    private func chooseApplication() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.applicationBundle]

        guard panel.runModal() == .OK, let url = panel.url else {
            return
        }

        tool.applicationPath = url.path

        if let bundle = Bundle(url: url) {
            if let bundleIdentifier = bundle.bundleIdentifier {
                tool.bundleIdentifiers = [bundleIdentifier]
            }

            let displayName = bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
                ?? bundle.object(forInfoDictionaryKey: "CFBundleName") as? String

            if let displayName = displayName?.nilIfEmpty,
               tool.title == L10n.string("New Tool") || tool.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                tool.title = displayName
            }
        }

        tool.iconMode = .applicationIcon
    }
}

struct FileListView: View {
    @EnvironmentObject private var browser: FileBrowserViewModel

    var body: some View {
        VStack(spacing: 0) {
            if browser.viewMode == .list {
                FileHeaderRow()
            }

            if browser.displayedItems.isEmpty {
                Spacer()
                Text(browser.emptyListMessage)
                    .foregroundStyle(.secondary)
                Spacer()
            } else {
                switch browser.viewMode {
                case .list:
                    FileListRowsView()
                case .icons:
                    FileIconGridView()
                case .columns:
                    FileColumnBrowserView()
                case .gallery:
                    FileGalleryView()
                }
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            browser.activateFilePane()
        }
        .onDrop(
            of: ShodanaTransferType.urlDropTypeIdentifiers,
            isTargeted: nil
        ) { providers in
            browser.dropItems(from: providers, into: browser.currentURL)
        }
        .contextMenu {
            FolderContextMenu()
        }
    }
}

struct FileListRowsView: View {
    @EnvironmentObject private var browser: FileBrowserViewModel

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(browser.groupedItems) { group in
                    if browser.groupMode != .none {
                        FileGroupHeader(title: group.title)
                            .padding(.horizontal, 14)
                    }

                    ForEach(Array(group.items.enumerated()), id: \.element.id) { index, item in
                        FileListRowContainer(item: item, isStriped: index % 2 == 1)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .background(Color(nsColor: .textBackgroundColor))
    }
}

struct FileListRowContainer: View {
    @EnvironmentObject private var browser: FileBrowserViewModel

    let item: FileItem
    let isStriped: Bool

    private var isSelected: Bool {
        browser.selectedIDs.contains(item.url)
    }

    private var rowBackground: Color {
        if isSelected {
            return Color.accentColor.opacity(0.18)
        }

        return isStriped
            ? Color(nsColor: .controlBackgroundColor).opacity(0.45)
            : Color.clear
    }

    var body: some View {
        FileRow(item: item)
            .padding(.horizontal, FileListLayout.rowHorizontalPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(rowBackground)
            .contentShape(Rectangle())
            .contextMenu {
                FileContextMenu(item: item)
            }
            .simultaneousGesture(TapGesture(count: 1).onEnded {
                browser.select(item)
            })
            .simultaneousGesture(TapGesture(count: 2).onEnded {
                browser.select(item)
                browser.open(item)
            })
            .overlay(FileDragInteractionView(item: item).environmentObject(browser))
            .onDrop(
                of: ShodanaTransferType.urlDropTypeIdentifiers,
                isTargeted: nil
            ) { providers in
                guard item.canNavigateInto else {
                    return false
                }

                return browser.dropItems(from: providers, into: item.url)
            }
    }
}

struct FileIconGridView: View {
    @EnvironmentObject private var browser: FileBrowserViewModel

    private let columns = [
        GridItem(.adaptive(minimum: 104, maximum: 140), spacing: 12)
    ]

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 10) {
                ForEach(browser.groupedItems) { group in
                    if browser.groupMode != .none {
                        FileGroupHeader(title: group.title)
                            .padding(.horizontal, 12)
                    }

                    LazyVGrid(columns: columns, alignment: .leading, spacing: 12) {
                        ForEach(group.items) { item in
                            FileInteractiveItem(item: item) {
                                FileIconCell(item: item)
                            }
                        }
                    }
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }
}

struct FileGroupHeader: View {
    let title: String

    var body: some View {
        Text(title)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .textCase(.uppercase)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 8)
            .padding(.bottom, 4)
    }
}

struct FileInteractiveItem<Content: View>: View {
    @EnvironmentObject private var browser: FileBrowserViewModel

    let item: FileItem
    @ViewBuilder let content: () -> Content

    var body: some View {
        content()
            .contentShape(Rectangle())
            .contextMenu {
                FileContextMenu(item: item)
            }
            .simultaneousGesture(TapGesture(count: 1).onEnded {
                browser.select(item)
            })
            .simultaneousGesture(TapGesture(count: 2).onEnded {
                browser.select(item)
                browser.open(item)
            })
            .overlay(FileDragInteractionView(item: item).environmentObject(browser))
            .onDrop(
                of: ShodanaTransferType.urlDropTypeIdentifiers,
                isTargeted: nil
            ) { providers in
                guard item.canNavigateInto else {
                    return false
                }

                return browser.dropItems(from: providers, into: item.url)
            }
    }
}

struct FileColumnPane: Identifiable {
    let id = UUID()
    var title: String
    var items: [FileItem] = []
    var previewItem: FileItem?
    var isLoading = false
    var errorMessage: String?
}

struct FileColumnBrowserView: View {
    @EnvironmentObject private var browser: FileBrowserViewModel

    @State private var panes: [FileColumnPane] = []
    @State private var loadTask: Task<Void, Never>?

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 0) {
                ForEach(Array(panes.enumerated()), id: \.element.id) { index, pane in
                    FileColumnPaneView(pane: pane) { item in
                        select(item, inPaneAt: index)
                    }
                    .environmentObject(browser)

                    Divider()
                }
            }
            .frame(maxHeight: .infinity, alignment: .topLeading)
        }
        .background(Color(nsColor: .textBackgroundColor))
        .onAppear {
            syncRootPane()
        }
        .onChange(of: browser.currentURL) { _, _ in
            syncRootPane()
        }
        .onChange(of: browser.displayedItems) { _, _ in
            updateRootPaneItems()
        }
        .onDisappear {
            loadTask?.cancel()
        }
    }

    private func syncRootPane() {
        loadTask?.cancel()
        panes = [
                FileColumnPane(
                title: rootTitle,
                items: browser.displayedItems
            )
        ]
    }

    private func updateRootPaneItems() {
        if panes.isEmpty {
            syncRootPane()
        } else {
            panes[0].title = rootTitle
            panes[0].items = browser.displayedItems
        }
    }

    private func select(_ item: FileItem, inPaneAt index: Int) {
        browser.select(item)
        loadTask?.cancel()

        panes = Array(panes.prefix(index + 1))

        if item.canNavigateInto {
            let loadingPane = FileColumnPane(
                title: item.displayName,
                isLoading: true
            )
            panes.append(loadingPane)
            let loadingPaneID = loadingPane.id

            loadTask = Task { @MainActor in
                do {
                    let childItems = try await browser.itemsForDisplay(at: item.url)

                    guard !Task.isCancelled,
                          let paneIndex = panes.firstIndex(where: { $0.id == loadingPaneID }) else {
                        return
                    }

                    panes[paneIndex] = FileColumnPane(
                        title: item.displayName,
                        items: childItems
                    )
                } catch {
                    guard !Task.isCancelled,
                          let paneIndex = panes.firstIndex(where: { $0.id == loadingPaneID }) else {
                        return
                    }

                    panes[paneIndex] = FileColumnPane(
                        title: item.displayName,
                        errorMessage: error.localizedDescription
                    )
                }
            }
        } else {
            panes.append(
                FileColumnPane(
                    title: item.displayName,
                    previewItem: item
                )
            )
        }
    }

    private func title(for url: URL) -> String {
        if SFTPClient.isSFTPURL(url) {
            let path = SFTPClient.remotePath(for: url)
            return path == "/" ? (url.host(percentEncoded: false) ?? "SFTP") : URL(fileURLWithPath: path).lastPathComponent
        }

        if S3Client.isS3URL(url) {
            let prefix = S3Client.prefix(for: url).withoutTrailingSlashes
            return prefix.isEmpty ? (url.host(percentEncoded: false) ?? "S3") : URL(fileURLWithPath: prefix).lastPathComponent
        }

        let displayName = FileManager.default.displayName(atPath: url.path)
        return displayName.isEmpty ? url.path : displayName
    }

    private var rootTitle: String {
        browser.contentMode == .search
            ? L10n.string("Search Results")
            : title(for: browser.currentURL)
    }
}

struct FileColumnPaneView: View {
    @EnvironmentObject private var browser: FileBrowserViewModel

    let pane: FileColumnPane
    let onSelect: (FileItem) -> Void

    var body: some View {
        VStack(spacing: 0) {
            Text(pane.title)
                .font(.caption.weight(.semibold))
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10)
                .frame(height: 30)
                .background(Color(nsColor: .windowBackgroundColor))

            if pane.isLoading {
                Spacer()
                ProgressView()
                    .controlSize(.small)
                Spacer()
            } else if let errorMessage = pane.errorMessage {
                Spacer()
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(16)
                Spacer()
            } else if let item = pane.previewItem {
                FileGalleryPreviewPane(item: item, compact: true)
                    .padding(12)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(browser.groupedItems(for: pane.items)) { group in
                            if browser.groupMode != .none {
                                FileGroupHeader(title: group.title)
                                    .padding(.horizontal, 10)
                            }

                            ForEach(group.items) { item in
                                FileColumnRow(item: item, onSelect: onSelect)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                }
            }
        }
        .frame(width: 280)
        .frame(maxHeight: .infinity)
    }
}

struct FileColumnRow: View {
    @EnvironmentObject private var browser: FileBrowserViewModel

    let item: FileItem
    let onSelect: (FileItem) -> Void

    private var isSelected: Bool {
        browser.selectedIDs.contains(item.url)
    }

    var body: some View {
        HStack(spacing: 8) {
            FileSystemIcon(item: item, size: 20)

            Text(item.displayName)
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer(minLength: 8)

            if item.canNavigateInto {
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .font(.system(size: 13))
        .padding(.horizontal, 10)
        .frame(height: 28)
        .background(isSelected ? Color.accentColor.opacity(0.18) : Color.clear)
        .contentShape(Rectangle())
        .contextMenu {
            FileContextMenu(item: item)
        }
        .simultaneousGesture(TapGesture(count: 1).onEnded {
            onSelect(item)
        })
        .simultaneousGesture(TapGesture(count: 2).onEnded {
            browser.select(item)
            browser.open(item)
        })
        .overlay(
            FileDragInteractionView(
                item: item,
                onSingleClick: { selectedItem in
                    onSelect(selectedItem)
                },
                onDoubleClick: { selectedItem in
                    browser.select(selectedItem)
                    browser.open(selectedItem)
                }
            )
            .environmentObject(browser)
        )
        .onDrop(
            of: ShodanaTransferType.urlDropTypeIdentifiers,
            isTargeted: nil
        ) { providers in
            guard item.canNavigateInto else {
                return false
            }

            return browser.dropItems(from: providers, into: item.url)
        }
    }
}

struct FileGalleryView: View {
    @EnvironmentObject private var browser: FileBrowserViewModel

    private var previewItem: FileItem {
        browser.selectedItems.last ?? browser.displayedItems[0]
    }

    var body: some View {
        VStack(spacing: 0) {
            FileGalleryPreviewPane(item: previewItem, compact: false)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(18)

            Divider()

            ScrollView(.horizontal) {
                LazyHStack(alignment: .top, spacing: 16) {
                    ForEach(browser.groupedItems) { group in
                        VStack(alignment: .leading, spacing: 8) {
                            if browser.groupMode != .none {
                                Text(group.title)
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.secondary)
                                    .textCase(.uppercase)
                                    .padding(.leading, 4)
                            }

                            HStack(spacing: 10) {
                                ForEach(group.items) { item in
                                    FileInteractiveItem(item: item) {
                                        FileGalleryThumbnailCell(item: item)
                                    }
                                }
                            }
                        }
                    }
                }
                .padding(12)
            }
            .frame(height: browser.groupMode == .none ? 112 : 134)
            .background(Color(nsColor: .windowBackgroundColor))
        }
        .background(Color(nsColor: .textBackgroundColor))
    }
}

struct FileGalleryPreviewPane: View {
    let item: FileItem
    let compact: Bool

    var body: some View {
        VStack(spacing: compact ? 12 : 18) {
            FilePreviewVisual(item: item, compact: compact)

            VStack(spacing: 6) {
                Text(item.displayName)
                    .font(compact ? .headline : .title2.weight(.semibold))
                    .lineLimit(compact ? 2 : 3)
                    .multilineTextAlignment(.center)
                    .truncationMode(.middle)

                VStack(spacing: 4) {
                    if !item.formattedModifiedAt.isEmpty {
                        FilePreviewMetadataRow(title: "Modified", value: item.formattedModifiedAt)
                    }

                    if !item.formattedSize.isEmpty {
                        FilePreviewMetadataRow(title: "Size", value: item.formattedSize)
                    }

                    FilePreviewMetadataRow(title: "Kind", value: L10n.string(item.kind))
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            .frame(maxWidth: compact ? 220 : 420)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct FilePreviewVisual: View {
    let item: FileItem
    let compact: Bool

    var body: some View {
        QuickLookThumbnailView(
            item: item,
            maxWidth: compact ? 190 : 520,
            maxHeight: compact ? 160 : 340,
            fallbackIconSize: compact ? 82 : 128
        )
    }
}

struct QuickLookThumbnailView: View {
    let item: FileItem
    let maxWidth: CGFloat
    let maxHeight: CGFloat
    let fallbackIconSize: CGFloat

    @State private var thumbnail: NSImage?
    @State private var thumbnailURL: URL?

    var body: some View {
        Group {
            if let thumbnail, thumbnailURL == item.url {
                Image(nsImage: thumbnail)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: maxWidth, maxHeight: maxHeight)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            } else {
                FileSystemIcon(item: item, size: fallbackIconSize)
                    .frame(
                        width: fallbackIconSize + 42,
                        height: fallbackIconSize + 42
                    )
            }
        }
        .onAppear {
            loadThumbnail()
        }
        .onChange(of: item.url) { _, _ in
            loadThumbnail()
        }
    }

    private func loadThumbnail() {
        thumbnail = nil
        thumbnailURL = item.url

        guard !SFTPClient.isSFTPURL(item.url),
              !S3Client.isS3URL(item.url),
              !item.isDirectory else {
            return
        }

        let targetURL = item.url
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        let request = QLThumbnailGenerator.Request(
            fileAt: targetURL,
            size: CGSize(width: maxWidth, height: maxHeight),
            scale: scale,
            representationTypes: .all
        )

        QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { representation, _ in
            let image = representation?.nsImage

            Task { @MainActor in
                guard thumbnailURL == targetURL else {
                    return
                }

                thumbnail = image
            }
        }
    }
}

struct FilePreviewMetadataRow: View {
    let title: String
    let value: String

    var body: some View {
        HStack(spacing: 6) {
            Text(L10n.string(title))
                .frame(width: 68, alignment: .trailing)

            Text(value)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct FileGalleryThumbnailCell: View {
    @EnvironmentObject private var browser: FileBrowserViewModel

    let item: FileItem

    private var isSelected: Bool {
        browser.selectedIDs.contains(item.url)
    }

    var body: some View {
        VStack(spacing: 5) {
            FileSystemIcon(item: item, size: 34)
                .frame(width: 40, height: 34)

            Text(item.displayName)
                .font(.system(size: 11))
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .truncationMode(.middle)
                .frame(width: 82, height: 30, alignment: .top)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 7)
        .frame(width: 92, height: 86)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isSelected ? Color.accentColor.opacity(0.18) : Color.clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(isSelected ? Color.accentColor.opacity(0.55) : Color.clear, lineWidth: 1)
        )
        .overlay(alignment: .topTrailing) {
            if let gitStatus = browser.gitStatus(for: item) {
                GitStatusBadge(status: gitStatus)
                    .padding(3)
            }
        }
        .contentShape(Rectangle())
    }
}

struct FileDragInteractionView: NSViewRepresentable {
    @EnvironmentObject private var browser: FileBrowserViewModel

    let item: FileItem
    var onSingleClick: ((FileItem) -> Void)?
    var onDoubleClick: ((FileItem) -> Void)?

    init(
        item: FileItem,
        onSingleClick: ((FileItem) -> Void)? = nil,
        onDoubleClick: ((FileItem) -> Void)? = nil
    ) {
        self.item = item
        self.onSingleClick = onSingleClick
        self.onDoubleClick = onDoubleClick
    }

    func makeNSView(context: Context) -> FileDragInteractionNSView {
        FileDragInteractionNSView()
    }

    func updateNSView(_ view: FileDragInteractionNSView, context: Context) {
        view.browser = browser
        view.item = item
        view.onSingleClick = onSingleClick
        view.onDoubleClick = onDoubleClick
    }
}

@MainActor
final class FileDragInteractionNSView: NSView, NSDraggingSource {
    weak var browser: FileBrowserViewModel?
    var item: FileItem?
    var onSingleClick: ((FileItem) -> Void)?
    var onDoubleClick: ((FileItem) -> Void)?

    private var mouseDownEvent: NSEvent?
    private var didStartDrag = false
    private let dragStartThreshold: CGFloat = 4

    override func hitTest(_ point: NSPoint) -> NSView? {
        switch NSApp.currentEvent?.type {
        case .rightMouseDown, .rightMouseDragged, .rightMouseUp, .otherMouseDown, .otherMouseDragged, .otherMouseUp:
            return nil
        default:
            return super.hitTest(point)
        }
    }

    override func mouseDown(with event: NSEvent) {
        guard let browser, let item else {
            return
        }

        didStartDrag = false
        mouseDownEvent = event
        browser.activateFilePane()

        if event.clickCount == 2 {
            if let onDoubleClick {
                onDoubleClick(item)
            } else {
                let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
                if !browser.selectedIDs.contains(item.url) || flags.contains(.command) || flags.contains(.shift) {
                    browser.select(item)
                }
                browser.open(item)
            }
            mouseDownEvent = nil
        } else {
            if let onSingleClick {
                onSingleClick(item)
            } else {
                let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
                if !browser.selectedIDs.contains(item.url) || flags.contains(.command) || flags.contains(.shift) {
                    browser.select(item)
                }
            }
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard !didStartDrag,
              let browser,
              let item,
              let mouseDownEvent else {
            return
        }

        let deltaX = event.locationInWindow.x - mouseDownEvent.locationInWindow.x
        let deltaY = event.locationInWindow.y - mouseDownEvent.locationInWindow.y
        let draggedDistance = hypot(deltaX, deltaY)

        guard draggedDistance >= dragStartThreshold else {
            return
        }

        let urls = browser.draggedURLsForDraggingSession(for: item)
        let location = convert(mouseDownEvent.locationInWindow, from: nil)
        let draggingItems = urls.enumerated().map { index, url in
            let draggingItem = NSDraggingItem(pasteboardWriter: browser.pasteboardWriter(forDraggedURL: url))
            let offset = CGFloat(index) * 3
            draggingItem.setDraggingFrame(
                NSRect(x: location.x - 16 + offset, y: location.y - 16 - offset, width: 32, height: 32),
                contents: browser.dragImage(forDraggedURL: url)
            )
            return draggingItem
        }

        guard !draggingItems.isEmpty else {
            return
        }

        didStartDrag = true
        beginDraggingSession(with: draggingItems, event: mouseDownEvent, source: self)
    }

    override func mouseUp(with event: NSEvent) {
        mouseDownEvent = nil
        didStartDrag = false
    }

    override func rightMouseDown(with event: NSEvent) {
        nextResponder?.rightMouseDown(with: event)
    }

    func draggingSession(
        _ session: NSDraggingSession,
        sourceOperationMaskFor context: NSDraggingContext
    ) -> NSDragOperation {
        .copy
    }

    func ignoreModifierKeys(for session: NSDraggingSession) -> Bool {
        false
    }
}

struct FileIconCell: View {
    @EnvironmentObject private var browser: FileBrowserViewModel

    let item: FileItem

    private var isSelected: Bool {
        browser.selectedIDs.contains(item.url)
    }

    var body: some View {
        VStack(spacing: 7) {
            FileSystemIcon(item: item, size: 46)
                .frame(width: 52, height: 46)

            Text(item.displayName)
                .font(.system(size: 12))
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .truncationMode(.middle)
                .frame(width: 92, height: 34, alignment: .top)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 8)
        .frame(width: 108, height: 104)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isSelected ? Color.accentColor.opacity(0.18) : Color.clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(isSelected ? Color.accentColor.opacity(0.55) : Color.clear, lineWidth: 1)
        )
        .overlay(alignment: .topTrailing) {
            if let gitStatus = browser.gitStatus(for: item) {
                GitStatusBadge(status: gitStatus)
                    .padding(3)
            }
        }
        .contentShape(Rectangle())
    }
}

struct FileSystemIcon: View {
    let item: FileItem
    let size: CGFloat

    var body: some View {
        if SFTPClient.isSFTPURL(item.url) || S3Client.isS3URL(item.url) {
            Image(systemName: item.systemImageName)
                .resizable()
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(item.isDirectory ? Color.accentColor : Color.secondary)
                .aspectRatio(contentMode: .fit)
                .frame(width: size, height: size)
        } else {
            Image(nsImage: NSWorkspace.shared.icon(forFile: item.url.path))
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: size, height: size)
        }
    }
}

private enum FileListLayout {
    static let rowHorizontalPadding: CGFloat = 14
    static let columnHorizontalPadding: CGFloat = 6
    static let gitStatusColumnWidth: CGFloat = 58
    static let cloudStatusColumnWidth: CGFloat = 66
    static let modifiedColumnWidth: CGFloat = 180
    static let sizeColumnWidth: CGFloat = 110
    static let kindColumnWidth: CGFloat = 170
}

struct FileHeaderRow: View {
    @EnvironmentObject private var browser: FileBrowserViewModel

    var body: some View {
        HStack(spacing: 0) {
            HeaderCell(title: "Name", column: .name)
                .frame(minWidth: 260, maxWidth: .infinity, alignment: .leading)

            if browser.canUseGit {
                Text(L10n.string("Git"))
                    .padding(.horizontal, FileListLayout.columnHorizontalPadding)
                    .frame(width: FileListLayout.gitStatusColumnWidth, alignment: .leading)
            }

            if browser.shouldShowCloudStatusColumn {
                Text(L10n.string("Cloud"))
                    .padding(.horizontal, FileListLayout.columnHorizontalPadding)
                    .frame(width: FileListLayout.cloudStatusColumnWidth, alignment: .center)
            }

            HeaderCell(title: "Modified", column: .modifiedAt)
                .frame(width: FileListLayout.modifiedColumnWidth, alignment: .leading)

            HeaderCell(title: "Size", column: .size)
                .frame(width: FileListLayout.sizeColumnWidth, alignment: .trailing)

            HeaderCell(title: "Kind", column: .kind)
                .frame(width: FileListLayout.kindColumnWidth, alignment: .leading)
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)
        .padding(.horizontal, FileListLayout.rowHorizontalPadding)
        .frame(height: 30)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

struct HeaderCell: View {
    @EnvironmentObject private var browser: FileBrowserViewModel

    let title: String
    let column: FileSortColumn

    var body: some View {
        Button {
            browser.sort(by: column)
        } label: {
            HStack(spacing: 4) {
                Text(L10n.string(title))

                if browser.sortColumn == column {
                    Image(systemName: browser.sortAscending ? "chevron.up" : "chevron.down")
                        .font(.caption2)
                }
            }
            .frame(maxWidth: .infinity, alignment: column == .size ? .trailing : .leading)
            .padding(.horizontal, FileListLayout.columnHorizontalPadding)
        }
        .buttonStyle(.plain)
    }
}

struct FileRow: View {
    @EnvironmentObject private var browser: FileBrowserViewModel

    let item: FileItem

    var body: some View {
        HStack(spacing: 0) {
            HStack(spacing: 8) {
                FileSystemIcon(item: item, size: 20)

                Text(item.displayName)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .padding(.horizontal, FileListLayout.columnHorizontalPadding)
            .frame(minWidth: 260, maxWidth: .infinity, alignment: .leading)

            if browser.canUseGit {
                GitStatusCell(status: browser.gitStatus(for: item))
                    .padding(.horizontal, FileListLayout.columnHorizontalPadding)
                    .frame(width: FileListLayout.gitStatusColumnWidth, alignment: .leading)
            }

            if browser.shouldShowCloudStatusColumn {
                CloudStatusCell(status: browser.cloudStatus(for: item))
                    .padding(.horizontal, FileListLayout.columnHorizontalPadding)
                    .frame(width: FileListLayout.cloudStatusColumnWidth, alignment: .center)
            }

            Text(item.formattedModifiedAt)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .padding(.horizontal, FileListLayout.columnHorizontalPadding)
                .frame(width: FileListLayout.modifiedColumnWidth, alignment: .leading)

            Text(item.formattedSize)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .padding(.horizontal, FileListLayout.columnHorizontalPadding)
                .frame(width: FileListLayout.sizeColumnWidth, alignment: .trailing)

            Text(L10n.string(item.kind))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
                .padding(.horizontal, FileListLayout.columnHorizontalPadding)
                .frame(width: FileListLayout.kindColumnWidth, alignment: .leading)
        }
        .font(.system(size: 13))
        .frame(height: 28)
        .contentShape(Rectangle())
    }
}

struct GitStatusCell: View {
    let status: GitFileStatus?

    var body: some View {
        if let status {
            GitStatusBadge(status: status)
        } else {
            Text("")
        }
    }
}

struct GitStatusBadge: View {
    let status: GitFileStatus

    var body: some View {
        Text(status.badge)
            .font(.system(size: 10, weight: .bold, design: .monospaced))
            .foregroundStyle(.white)
            .frame(minWidth: 17, minHeight: 15)
            .padding(.horizontal, 2)
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(status.listColor)
            )
            .help(L10n.string(status.titleKey))
    }
}

struct CloudStatusCell: View {
    let status: CloudFileStatus?

    var body: some View {
        if let status {
            CloudStatusBadge(status: status)
        } else {
            Text("")
        }
    }
}

struct CloudStatusBadge: View {
    let status: CloudFileStatus

    var body: some View {
        Image(systemName: status.listSystemImageName)
            .font(.system(size: 13, weight: .semibold))
            .symbolRenderingMode(.hierarchical)
            .foregroundStyle(.white)
            .frame(width: 25, height: 19)
            .background(
                RoundedRectangle(cornerRadius: 5)
                    .fill(status.listColor)
            )
            .help(L10n.string(status.titleKey))
    }
}

private extension GitFileStatus {
    var listColor: Color {
        switch self {
        case .modified:
            return .blue
        case .added:
            return .green
        case .deleted:
            return .red
        case .renamed:
            return .cyan
        case .untracked:
            return .orange
        case .ignored:
            return .gray
        case .conflicted:
            return .purple
        }
    }
}

private extension CloudFileStatus {
    var listSystemImageName: String {
        switch self {
        case .synced:
            return "checkmark.circle.fill"
        case .cloudOnly:
            return "icloud.fill"
        case .syncing:
            return "arrow.triangle.2.circlepath"
        case .error:
            return "exclamationmark.triangle.fill"
        case .pinned:
            return "pin.fill"
        case .unknown:
            return "questionmark.circle.fill"
        }
    }

    var listColor: Color {
        switch self {
        case .synced:
            return Color(red: 0.25, green: 0.52, blue: 0.39)
        case .cloudOnly:
            return Color(red: 0.28, green: 0.47, blue: 0.64)
        case .syncing:
            return Color(red: 0.70, green: 0.48, blue: 0.24)
        case .error:
            return Color(red: 0.66, green: 0.26, blue: 0.25)
        case .pinned:
            return Color(red: 0.29, green: 0.53, blue: 0.55)
        case .unknown:
            return Color(red: 0.45, green: 0.45, blue: 0.47)
        }
    }
}

struct FileContextMenu: View {
    @EnvironmentObject private var browser: FileBrowserViewModel

    let item: FileItem

    var body: some View {
        Button(L10n.string("Open")) {
            browser.open(item)
        }

        if item.isPackage && !SFTPClient.isSFTPURL(item.url) && !S3Client.isS3URL(item.url) {
            Button(L10n.string("Show Package Contents")) {
                browser.showPackageContents(item)
            }
        }

        Button(L10n.string("Get Info")) {
            browser.beginGetInfo(item)
        }

        Divider()

        Button(L10n.string("Rename")) {
            browser.beginRename(item)
        }

        Button(L10n.string("Duplicate")) {
            browser.duplicate(item)
        }

        Menu(L10n.string("Compress")) {
            ForEach(ArchiveFormat.allCases) { format in
                Button(L10n.string(format.titleKey)) {
                    browser.compress(item, as: format)
                }
            }
        }
        .disabled(!browser.canCompress(item))

        Button(L10n.string("Extract")) {
            browser.extract(item)
        }
        .disabled(!browser.canExtract(item))

        Divider()

        Button(L10n.string("Copy")) {
            browser.selectOnly(item.url)
            browser.copySelection()
        }

        Button(L10n.string("Cut")) {
            browser.selectOnly(item.url)
            browser.cutSelection()
        }

        Button(L10n.string("Paste Into Folder")) {
            browser.paste(into: item.url)
        }
        .disabled(!item.canNavigateInto)

        Divider()

        Button(L10n.string("Copy Path")) {
            browser.copyPath(item)
        }

        Button(L10n.string("Reveal in Finder")) {
            browser.revealInFinder(item)
        }
        .disabled(SFTPClient.isSFTPURL(item.url) || S3Client.isS3URL(item.url))

        Button(L10n.string("Open in Terminal")) {
            browser.openInTerminal(item.url)
        }
        .disabled(S3Client.isS3URL(item.url))

        Button(L10n.string("Open in iTerm")) {
            browser.openIniTerm(item.url)
        }
        .disabled(!browser.isITermAvailable || S3Client.isS3URL(item.url))

        if browser.canUseGit {
            Divider()
            GitItemContextMenu(item: item)
        }

        Divider()

        Button(L10n.string("Move to Trash")) {
            browser.selectOnly(item.url)
            browser.trashSelection()
        }
    }
}

struct FolderContextMenu: View {
    @EnvironmentObject private var browser: FileBrowserViewModel

    var body: some View {
        Button(L10n.string("New Folder")) {
            browser.createFolder()
        }

        Button(L10n.string("New File")) {
            browser.createFile()
        }

        Divider()

        Button(L10n.string("Paste")) {
            browser.pasteIntoCurrentFolder()
        }

        if browser.canUseGit {
            Divider()
            GitFolderContextMenu()
        }

        if browser.canCloneRepository {
            Divider()

            Button(L10n.string("Clone Repository...")) {
                browser.beginGitClone()
            }
        }

        Divider()

        Button(L10n.string("Open in Terminal")) {
            browser.openInTerminal(browser.currentURL)
        }
        .disabled(browser.isCurrentS3)

        Button(L10n.string("Open in iTerm")) {
            browser.openIniTerm(browser.currentURL)
        }
        .disabled(!browser.isITermAvailable || browser.isCurrentS3)

        Divider()

        Button(L10n.string("Copy Path")) {
            browser.copyPath(browser.currentURL)
        }

        Button(L10n.string("Reveal in Finder")) {
            browser.revealInFinder(browser.currentURL)
        }
        .disabled(browser.isCurrentRemote)
    }
}

struct GitItemContextMenu: View {
    @EnvironmentObject private var browser: FileBrowserViewModel

    let item: FileItem

    var body: some View {
        Menu(L10n.string("Git")) {
            Button(L10n.string("Git Pull")) {
                browser.gitPull()
            }

            Button(L10n.string("Git Push")) {
                browser.gitPush()
            }

            Divider()

            Button(L10n.string("Git Add Selected")) {
                browser.gitAdd(item)
            }
            .disabled(!browser.canGitAdd(item))

            Button(L10n.string("Git Commit Selected...")) {
                browser.beginGitCommit(item)
            }
            .disabled(!browser.canGitCommit(item))

            Button(L10n.string("Git Diff Selected")) {
                browser.gitDiff(item)
            }
            .disabled(!browser.canGitAdd(item))

            Button(L10n.string("Git History Selected")) {
                browser.gitHistory(item)
            }
            .disabled(!browser.canGitAdd(item))

            Divider()

            Button(L10n.string("Checkout Branch...")) {
                browser.beginGitCheckoutBranch()
            }

            Button(L10n.string("Merge Branch...")) {
                browser.beginGitMergeBranch()
            }
        }
    }
}

struct GitFolderContextMenu: View {
    @EnvironmentObject private var browser: FileBrowserViewModel

    var body: some View {
        Menu(L10n.string("Git")) {
            Button(L10n.string("Git Pull")) {
                browser.gitPull()
            }

            Button(L10n.string("Git Push")) {
                browser.gitPush()
            }

            Divider()

            Button(L10n.string("Git Add Selected")) {
                browser.gitAddSelection()
            }
            .disabled(!browser.canGitAddSelection)

            Button(L10n.string("Git Commit Selected...")) {
                browser.beginGitCommitSelection()
            }
            .disabled(!browser.canGitCommitSelection)

            Button(L10n.string("Git Diff")) {
                browser.gitDiffRepository()
            }

            Button(L10n.string("Git History")) {
                browser.gitHistoryRepository()
            }

            Button(L10n.string("Clone Repository...")) {
                browser.beginGitClone()
            }
            .disabled(!browser.canCloneRepository)

            Divider()

            Button(L10n.string("Checkout Branch...")) {
                browser.beginGitCheckoutBranch()
            }

            Button(L10n.string("Merge Branch...")) {
                browser.beginGitMergeBranch()
            }
        }
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}

struct ConnectServerSheet: View {
    @EnvironmentObject private var browser: FileBrowserViewModel
    @FocusState private var focusedField: ConnectServerField?

    private enum ConnectServerField {
        case name
        case address
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text(L10n.string("Connect"))
                    .font(.headline)

                Text(L10n.string("Choose a protocol and enter a remote address."))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Picker(L10n.string("Protocol"), selection: $browser.connectProtocol) {
                ForEach(RemoteConnectionKind.allCases) { kind in
                    Text(L10n.string(kind.displayName)).tag(kind)
                }
            }
            .pickerStyle(.segmented)
            .onChange(of: browser.connectProtocol) { _, newValue in
                browser.connectServerAddress = newValue.defaultAddress
                browser.connectAWSProfile = ""

                if newValue == .s3 {
                    browser.refreshAWSProfiles()
                }
            }

            TextField(L10n.string("Location name (optional)"), text: $browser.connectServerDisplayName)
                .textFieldStyle(.roundedBorder)
                .focused($focusedField, equals: .name)
                .onSubmit {
                    focusedField = .address
                }

            TextField(browser.connectProtocol.placeholder, text: $browser.connectServerAddress)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: NSFont.systemFontSize, design: .monospaced))
                .focused($focusedField, equals: .address)
                .onSubmit {
                    browser.commitConnectServerDialog()
                }

            if browser.connectProtocol == .s3 {
                Picker(L10n.string("AWS profile"), selection: $browser.connectAWSProfile) {
                    Text(L10n.string("Default")).tag("")

                    ForEach(browser.awsProfiles, id: \.self) { profile in
                        Text(profile).tag(profile)
                    }
                }
                .pickerStyle(.menu)
            }

            HStack {
                Spacer()

                Button(L10n.string("Cancel")) {
                    browser.cancelConnectServerDialog()
                }
                .keyboardShortcut(.cancelAction)

                Button(L10n.string("Connect")) {
                    browser.commitConnectServerDialog()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 460)
        .onAppear {
            if browser.connectProtocol == .s3 {
                browser.refreshAWSProfiles()
            }

            DispatchQueue.main.async {
                focusedField = .address
            }
        }
    }
}

struct LocationContextMenu: View {
    @EnvironmentObject private var browser: FileBrowserViewModel

    let location: SidebarLocation

    var body: some View {
        Button(L10n.string(location.isUnavailable ? "Reconnect" : "Open")) {
            browser.open(location)
        }

        Divider()

        Button(L10n.string("Open in Terminal")) {
            browser.openInTerminal(location.url)
        }
        .disabled(location.isUnavailable || S3Client.isS3URL(location.url))

        Button(L10n.string("Open in iTerm")) {
            browser.openIniTerm(location.url)
        }
        .disabled(!browser.isITermAvailable || location.isUnavailable || S3Client.isS3URL(location.url))

        Divider()

        Button(L10n.string("Copy Path")) {
            browser.copyPath(location.url)
        }
        .disabled(location.isUnavailable)

        Button(L10n.string("Reveal in Finder")) {
            browser.revealInFinder(location.url)
        }
        .disabled(location.isUnavailable || SFTPClient.isSFTPURL(location.url) || S3Client.isS3URL(location.url))

        if location.canDisconnect {
            Divider()

            Button(L10n.string("Disconnect")) {
                browser.disconnect(location)
            }
        }

        if location.canRemoveFromFavorites {
            Divider()

            Button(L10n.string("Remove from Favorites")) {
                browser.removeFavorite(location)
            }
        }
    }
}

struct StatusBarView: View {
    @EnvironmentObject private var browser: FileBrowserViewModel

    var body: some View {
        HStack(spacing: 12) {
            if let branchName = browser.gitBranchDisplayName {
                GitBranchStatusLabel(branchName: branchName)
            }

            Text(L10n.format("items.count", browser.displayedItems.count))

            if !browser.selectedIDs.isEmpty {
                Text(L10n.format("items.selected", browser.selectedIDs.count))
            }

            if let operation = browser.pendingClipboardOperation {
                Text(L10n.string(operation.mode == .cut ? "Cut ready" : "Copy ready"))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Text(browser.currentDisplayAddress)
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundStyle(.secondary)
        }
        .font(.caption)
        .padding(.horizontal, 12)
        .frame(height: 26)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

struct GitBranchStatusLabel: View {
    @EnvironmentObject private var browser: FileBrowserViewModel

    let branchName: String

    var body: some View {
        Menu {
            GitRepositoryMenuItems()
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "point.3.connected.trianglepath.dotted")
                    .foregroundStyle(.secondary)

                Text(branchName)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(.secondary)

                if let indicator = browser.gitBranchTrackingIndicator {
                    Text(indicator)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(indicatorColor)
                        .help(browser.gitBranchTrackingDescription ?? "")
                }
            }
        }
        .frame(maxWidth: 210, alignment: .leading)
        .buttonStyle(.plain)
        .help(L10n.string("Git actions"))
    }

    private var indicatorColor: Color {
        guard let trackingStatus = browser.gitRepositoryInfo?.trackingStatus else {
            return Color.accentColor
        }

        if trackingStatus.aheadCount > 0, trackingStatus.behindCount > 0 {
            return .orange
        }

        if trackingStatus.aheadCount > 0 {
            return .green
        }

        if trackingStatus.behindCount > 0 {
            return .red
        }

        return Color.accentColor
    }
}

struct GitRepositoryMenuItems: View {
    @EnvironmentObject private var browser: FileBrowserViewModel

    var body: some View {
        Button(L10n.string("Git Pull")) {
            browser.gitPull()
        }

        Button(L10n.string("Git Push")) {
            browser.gitPush()
        }

        Divider()

        Button(L10n.string("Git Diff")) {
            browser.gitDiffRepository()
        }

        Button(L10n.string("Git History")) {
            browser.gitHistoryRepository()
        }

        Button(L10n.string("Clone Repository...")) {
            browser.beginGitClone()
        }
        .disabled(!browser.canCloneRepository)

        Divider()

        Button(L10n.string("Checkout Branch...")) {
            browser.beginGitCheckoutBranch()
        }

        Button(L10n.string("Merge Branch...")) {
            browser.beginGitMergeBranch()
        }
    }
}

struct GitOperationResultSheet: View {
    let result: GitOperationResult
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(L10n.string("Git Result"))
                .font(.headline)

            VStack(alignment: .leading, spacing: 8) {
                FileInfoRow(title: "Action", value: result.actionTitle)
                FileInfoRow(title: "Summary", value: result.summary)
            }

            Text(L10n.string("Details"))
                .font(.subheadline.weight(.semibold))

            ScrollView {
                Text(result.detail)
                    .font(.system(size: 12, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .padding(10)
            }
            .frame(minHeight: 160, maxHeight: 260)
            .background(Color(nsColor: .textBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 6))

            HStack {
                Spacer()

                Button(L10n.string("Copy Details")) {
                    let pasteboard = NSPasteboard.general
                    pasteboard.clearContents()
                    pasteboard.setString(result.detail, forType: .string)
                }

                Button(L10n.string("Close")) {
                    onClose()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 560)
    }
}

struct FileInfoSheet: View {
    let request: FileInfoRequest
    let onClose: () -> Void

    private var items: [FileItem] {
        request.items
    }

    private var totalSize: Int64? {
        let sizes = items.compactMap(\.size)

        guard !sizes.isEmpty else {
            return nil
        }

        return sizes.reduce(0, +)
    }

    private var locationText: String {
        guard let firstURL = items.first?.url else {
            return ""
        }

        if items.count == 1 {
            return displayString(for: firstURL.deletingLastPathComponent())
        }

        let parentURLs = Set(items.map { displayString(for: $0.url.deletingLastPathComponent()) })

        guard parentURLs.count == 1, let parentURL = parentURLs.first else {
            return L10n.string("Multiple Locations")
        }

        return parentURL
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                if items.count == 1, let item = items.first {
                    FileSystemIcon(item: item, size: 42)
                } else {
                    Image(systemName: "square.stack.3d.up")
                        .font(.system(size: 36))
                        .foregroundStyle(.secondary)
                        .frame(width: 42, height: 42)
                }

                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.headline)
                        .lineLimit(1)
                        .truncationMode(.middle)

                    Text(subtitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                if let item = items.first, items.count == 1 {
                    FileInfoRow(title: "Name", value: item.displayName)
                    FileInfoRow(title: "Kind", value: L10n.string(item.kind))
                    FileInfoRow(title: "Location", value: locationText)
                    FileInfoRow(title: "Size", value: item.formattedSize.nilIfEmpty ?? L10n.string("Calculating Size Unavailable"))
                    FileInfoRow(title: "Modified", value: item.formattedModifiedAt.nilIfEmpty ?? L10n.string("Unknown"))
                    FileInfoRow(title: "Path", value: displayString(for: item.url))
                } else {
                    FileInfoRow(title: "Items", value: L10n.format("items.count", items.count))
                    FileInfoRow(title: "Location", value: locationText)
                    FileInfoRow(
                        title: "Total Size",
                        value: totalSize.map { $0.formatted(.byteCount(style: .file)) } ?? L10n.string("Calculating Size Unavailable")
                    )
                }
            }

            HStack {
                Spacer()

                Button(L10n.string("Close")) {
                    onClose()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 520)
    }

    private var title: String {
        if items.count == 1, let item = items.first {
            return item.displayName
        }

        return L10n.string("Multiple Items")
    }

    private var subtitle: String {
        items.count == 1 ? L10n.string("Get Info") : L10n.format("items.count", items.count)
    }

    private func displayString(for url: URL) -> String {
        if SFTPClient.isSFTPURL(url) || S3Client.isS3URL(url) {
            return url.absoluteString
        }

        return url.path
    }
}

struct FileInfoRow: View {
    let title: String
    let value: String

    var body: some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 6) {
            GridRow {
                Text(L10n.string(title))
                    .foregroundStyle(.secondary)
                    .frame(width: 92, alignment: .trailing)

                Text(value)
                    .textSelection(.enabled)
                    .lineLimit(3)
                    .truncationMode(.middle)
            }
        }
        .font(.system(size: 13))
    }
}

struct GitCommitSheet: View {
    let request: GitCommitRequest
    let onCommit: (String) -> Void
    let onCancel: () -> Void

    @State private var message = ""
    @FocusState private var isFocused: Bool

    private var trimmedMessage: String {
        message.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L10n.string("Git Commit"))
                .font(.headline)

            Text(L10n.format("git.commit.items", request.items.count))
                .font(.subheadline)
                .foregroundStyle(.secondary)

            TextField(L10n.string("Commit message"), text: $message)
                .textFieldStyle(.roundedBorder)
                .focused($isFocused)
                .onSubmit {
                    guard !trimmedMessage.isEmpty else {
                        return
                    }

                    onCommit(message)
                }

            HStack {
                Spacer()

                Button(L10n.string("Cancel")) {
                    onCancel()
                }
                .keyboardShortcut(.cancelAction)

                Button(L10n.string("Commit")) {
                    onCommit(message)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(trimmedMessage.isEmpty)
            }
        }
        .padding(18)
        .frame(width: 420)
        .onAppear {
            isFocused = true
        }
    }
}

struct GitCloneSheet: View {
    let request: GitCloneRequest
    let onClone: (String, String) -> Void
    let onCancel: () -> Void

    @State private var repository = ""
    @State private var destinationName = ""
    @FocusState private var focusedField: GitCloneField?

    private enum GitCloneField {
        case repository
        case destinationName
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(L10n.string("Clone Repository"))
                .font(.headline)

            FileInfoRow(title: "Location", value: request.destinationURL.path)

            VStack(alignment: .leading, spacing: 5) {
                Text(L10n.string("Repository URL"))
                    .font(.caption)
                    .foregroundStyle(.secondary)

                TextField("git@github.com:owner/repository.git", text: $repository)
                    .textFieldStyle(.roundedBorder)
                    .focused($focusedField, equals: .repository)
                    .onSubmit {
                        cloneIfPossible()
                    }
            }

            VStack(alignment: .leading, spacing: 5) {
                Text(L10n.string("Destination Folder"))
                    .font(.caption)
                    .foregroundStyle(.secondary)

                TextField(L10n.string("Optional"), text: $destinationName)
                    .textFieldStyle(.roundedBorder)
                    .focused($focusedField, equals: .destinationName)
                    .onSubmit {
                        cloneIfPossible()
                    }
            }

            HStack {
                Spacer()

                Button(L10n.string("Cancel")) {
                    onCancel()
                }
                .keyboardShortcut(.cancelAction)

                Button(L10n.string("Clone")) {
                    cloneIfPossible()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(repository.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 520)
        .onAppear {
            focusedField = .repository
        }
    }

    private func cloneIfPossible() {
        guard !repository.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return
        }

        onClone(repository, destinationName)
    }
}

struct GitBranchSheet: View {
    let request: GitBranchRequest
    let onSelect: (String) -> Void
    let onCancel: () -> Void

    @State private var selectedBranch: String

    init(
        request: GitBranchRequest,
        onSelect: @escaping (String) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.request = request
        self.onSelect = onSelect
        self.onCancel = onCancel
        _selectedBranch = State(initialValue: request.branches.first ?? "")
    }

    private var titleKey: String {
        switch request.action {
        case .checkout:
            return "Checkout Branch"
        case .merge:
            return "Merge Branch"
        }
    }

    private var buttonTitleKey: String {
        switch request.action {
        case .checkout:
            return "Checkout"
        case .merge:
            return "Merge"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L10n.string(titleKey))
                .font(.headline)

            Picker(L10n.string("Branch"), selection: $selectedBranch) {
                ForEach(request.branches, id: \.self) { branch in
                    Text(branch).tag(branch)
                }
            }
            .pickerStyle(.menu)

            HStack {
                Spacer()

                Button(L10n.string("Cancel")) {
                    onCancel()
                }
                .keyboardShortcut(.cancelAction)

                Button(L10n.string(buttonTitleKey)) {
                    onSelect(selectedBranch)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(selectedBranch.isEmpty)
            }
        }
        .padding(18)
        .frame(width: 380)
    }
}

struct RenameSheet: View {
    let request: RenameRequest
    let onCommit: (String) -> Void
    let onCancel: () -> Void

    @State private var name: String
    @FocusState private var isFocused: Bool

    init(
        request: RenameRequest,
        onCommit: @escaping (String) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.request = request
        self.onCommit = onCommit
        self.onCancel = onCancel
        _name = State(initialValue: request.currentName)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L10n.string("Rename"))
                .font(.headline)

            TextField(L10n.string("Name"), text: $name)
                .textFieldStyle(.roundedBorder)
                .focused($isFocused)
                .onSubmit {
                    onCommit(name)
                }

            HStack {
                Spacer()

                Button(L10n.string("Cancel")) {
                    onCancel()
                }
                .keyboardShortcut(.cancelAction)

                Button(L10n.string("Rename")) {
                    onCommit(name)
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(18)
        .frame(width: 380)
        .onAppear {
            isFocused = true
        }
    }
}

private extension String {
    var withoutTrailingSlashes: String {
        var result = self

        while result.hasSuffix("/") {
            result.removeLast()
        }

        return result
    }
}
