import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @EnvironmentObject private var browser: FileBrowserViewModel
    @State private var sidebarWidth: CGFloat = 300
    @State private var pasteboardShortcutMonitor: Any?
    @State private var hostingWindow: NSWindow?

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
                    BrowserToolbarView()
                    Divider()
                    BreadcrumbBar()
                    Divider()
                    FileActionBarView()
                    Divider()
                    FileListView()
                    Divider()
                    StatusBarView()
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
            installPasteboardShortcutMonitor()
        }
        .onDisappear {
            removePasteboardShortcutMonitor()
        }
        .sheet(isPresented: $browser.isConnectServerDialogPresented) {
            ConnectServerSheet()
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
        .alert(
            "Action Failed",
            isPresented: Binding(
                get: { browser.errorMessage != nil },
                set: { isPresented in
                    if !isPresented {
                        browser.clearError()
                    }
                }
            )
        ) {
            Button("OK") {
                browser.clearError()
            }
        } message: {
            Text(browser.errorMessage ?? "")
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

    private func installPasteboardShortcutMonitor() {
        guard pasteboardShortcutMonitor == nil else {
            return
        }

        pasteboardShortcutMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
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
        .help("Resize sidebar")
        .accessibilityLabel("Resize sidebar")
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
            Text(section.title)
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
            Text("Network")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.top, 8)
                .padding(.bottom, 3)

            Button {
                browser.promptConnectToServer()
            } label: {
                Label("Connect...", systemImage: "network")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 12)
            .padding(.vertical, 4)

            Button {
                browser.reloadLocations()
            } label: {
                Label("Reload Locations", systemImage: "arrow.clockwise")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
            .help("Rescan cloud folders, mounted drives, and network volumes")
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
            Label(location.title, systemImage: location.systemImageName)
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

struct BrowserToolbarView: View {
    @EnvironmentObject private var browser: FileBrowserViewModel

    var body: some View {
        HStack(spacing: 8) {
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

            TextField("Path", text: $browser.addressText)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: NSFont.systemFontSize, design: .monospaced))
                .lineLimit(1)
                .onSubmit {
                    browser.submitAddress()
                }
                .help("Path")
                .frame(maxWidth: .infinity)
                .frame(height: 24)
                .layoutPriority(1)

            Button {
                browser.submitAddress()
            } label: {
                Image(systemName: "arrow.right.circle")
            }
            .help("Go")

            Toggle(isOn: $browser.showHiddenFiles) {
                Image(systemName: browser.showHiddenFiles ? "eye" : "eye.slash")
            }
            .toggleStyle(.button)
            .help("Show hidden files")

            ToolbarIconButton(systemImageName: "folder.badge.plus", help: "New Folder") {
                browser.createFolder()
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
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
        .help(help)
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
            Picker("View", selection: $browser.viewMode) {
                Image(systemName: "list.bullet")
                    .tag(BrowserViewMode.list)

                Image(systemName: "square.grid.2x2")
                    .tag(BrowserViewMode.icons)
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .frame(width: 92)
            .help("View mode")

            Divider()
                .frame(height: 22)

            ToolbarIconButton(systemImageName: "arrow.up", help: "Up") {
                browser.goUp()
            }
            .disabled(!browser.canGoUp)

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

            ToolbarIconButton(systemImageName: "terminal", help: "Open in Terminal") {
                browser.openInTerminal(browser.currentURL)
            }
            .disabled(browser.isCurrentS3)

            ToolbarIconButton(systemImageName: "terminal.fill", help: "Open in iTerm") {
                browser.openIniTerm(browser.currentURL)
            }
            .disabled(!browser.isITermAvailable || browser.isCurrentS3)

            Divider()
                .frame(height: 22)

            ToolbarIconButton(systemImageName: "globe", help: "Open selected folder in WebStorm") {
                browser.openSelectedFolderInWebStorm()
            }
            .disabled(!browser.canOpenSelectedFolderInWebStorm)

            ToolbarIconButton(systemImageName: "hammer", help: "Open selected folder in PyCharm") {
                browser.openSelectedFolderInPyCharm()
            }
            .disabled(!browser.canOpenSelectedFolderInPyCharm)

            ToolbarIconButton(systemImageName: "chevron.left.forwardslash.chevron.right", help: "Open selected folder in VSCode") {
                browser.openSelectedFolderInVSCode()
            }
            .disabled(!browser.canOpenSelectedFolderInVSCode)

            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .frame(height: 42)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

struct FileListView: View {
    @EnvironmentObject private var browser: FileBrowserViewModel

    var body: some View {
        VStack(spacing: 0) {
            if browser.viewMode == .list {
                FileHeaderRow()
            }

            if browser.items.isEmpty {
                Spacer()
                Text("Empty Folder")
                    .foregroundStyle(.secondary)
                Spacer()
            } else {
                switch browser.viewMode {
                case .list:
                    FileListRowsView()
                case .icons:
                    FileIconGridView()
                }
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            browser.activateFilePane()
        }
        .onDrop(
            of: MihakoTransferType.urlDropTypeIdentifiers,
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
                ForEach(browser.items) { item in
                    FileListRowContainer(item: item)
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

    private var isSelected: Bool {
        browser.selectedIDs.contains(item.url)
    }

    var body: some View {
        FileRow(item: item)
            .padding(.horizontal, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(isSelected ? Color.accentColor.opacity(0.18) : Color.clear)
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
            .onDrag {
                browser.dragProvider(for: item)
            }
            .onDrop(
                of: MihakoTransferType.urlDropTypeIdentifiers,
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
            LazyVGrid(columns: columns, alignment: .leading, spacing: 12) {
                ForEach(browser.items) { item in
                    FileIconCell(item: item)
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
                        .onDrag {
                            browser.dragProvider(for: item)
                        }
                        .onDrop(
                            of: MihakoTransferType.urlDropTypeIdentifiers,
                            isTargeted: nil
                        ) { providers in
                            guard item.canNavigateInto else {
                                return false
                            }

                            return browser.dropItems(from: providers, into: item.url)
                        }
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
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
            FileSystemIcon(url: item.url, size: 46)
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
        .contentShape(Rectangle())
    }
}

struct FileSystemIcon: View {
    let url: URL
    let size: CGFloat

    var body: some View {
        Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
            .resizable()
            .aspectRatio(contentMode: .fit)
            .frame(width: size, height: size)
    }
}

struct FileHeaderRow: View {
    @EnvironmentObject private var browser: FileBrowserViewModel

    var body: some View {
        HStack(spacing: 0) {
            HeaderCell(title: "Name", column: .name)
                .frame(minWidth: 260, maxWidth: .infinity, alignment: .leading)

            HeaderCell(title: "Modified", column: .modifiedAt)
                .frame(width: 180, alignment: .leading)

            HeaderCell(title: "Size", column: .size)
                .frame(width: 110, alignment: .trailing)

            HeaderCell(title: "Kind", column: .kind)
                .frame(width: 170, alignment: .leading)
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 14)
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
                Text(title)

                if browser.sortColumn == column {
                    Image(systemName: browser.sortAscending ? "chevron.up" : "chevron.down")
                        .font(.caption2)
                }
            }
            .frame(maxWidth: .infinity, alignment: column == .size ? .trailing : .leading)
        }
        .buttonStyle(.plain)
    }
}

struct FileRow: View {
    let item: FileItem

    var body: some View {
        HStack(spacing: 0) {
            HStack(spacing: 8) {
                FileSystemIcon(url: item.url, size: 20)

                Text(item.displayName)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .frame(minWidth: 260, maxWidth: .infinity, alignment: .leading)

            Text(item.formattedModifiedAt)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(width: 180, alignment: .leading)

            Text(item.formattedSize)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(width: 110, alignment: .trailing)

            Text(item.kind)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(width: 170, alignment: .leading)
        }
        .font(.system(size: 13))
        .frame(height: 28)
        .contentShape(Rectangle())
    }
}

struct FileContextMenu: View {
    @EnvironmentObject private var browser: FileBrowserViewModel

    let item: FileItem

    var body: some View {
        Button("Open") {
            browser.open(item)
        }

        Divider()

        Button("Rename") {
            browser.beginRename(item)
        }

        Button("Duplicate") {
            browser.duplicate(item)
        }

        Divider()

        Button("Copy") {
            browser.selectOnly(item.url)
            browser.copySelection()
        }

        Button("Cut") {
            browser.selectOnly(item.url)
            browser.cutSelection()
        }

        Button("Paste Into Folder") {
            browser.paste(into: item.url)
        }
        .disabled(!item.canNavigateInto)

        Divider()

        Button("Copy Path") {
            browser.copyPath(item)
        }

        Button("Reveal in Finder") {
            browser.revealInFinder(item)
        }
        .disabled(SFTPClient.isSFTPURL(item.url) || S3Client.isS3URL(item.url))

        Button("Open in Terminal") {
            browser.openInTerminal(item.url)
        }
        .disabled(S3Client.isS3URL(item.url))

        Button("Open in iTerm") {
            browser.openIniTerm(item.url)
        }
        .disabled(!browser.isITermAvailable || S3Client.isS3URL(item.url))

        Divider()

        Button("Move to Trash") {
            browser.selectOnly(item.url)
            browser.trashSelection()
        }
    }
}

struct FolderContextMenu: View {
    @EnvironmentObject private var browser: FileBrowserViewModel

    var body: some View {
        Button("New Folder") {
            browser.createFolder()
        }

        Button("New File") {
            browser.createFile()
        }

        Divider()

        Button("Paste") {
            browser.pasteIntoCurrentFolder()
        }

        Divider()

        Button("Open in Terminal") {
            browser.openInTerminal(browser.currentURL)
        }
        .disabled(browser.isCurrentS3)

        Button("Open in iTerm") {
            browser.openIniTerm(browser.currentURL)
        }
        .disabled(!browser.isITermAvailable || browser.isCurrentS3)

        Divider()

        Button("Copy Path") {
            browser.copyPath(browser.currentURL)
        }

        Button("Reveal in Finder") {
            browser.revealInFinder(browser.currentURL)
        }
        .disabled(browser.isCurrentRemote)
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
                Text("Connect")
                    .font(.headline)

                Text("Choose a protocol and enter a remote address.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Picker("Protocol", selection: $browser.connectProtocol) {
                ForEach(RemoteConnectionKind.allCases) { kind in
                    Text(kind.displayName).tag(kind)
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

            TextField("Location name (optional)", text: $browser.connectServerDisplayName)
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
                Picker("AWS profile", selection: $browser.connectAWSProfile) {
                    Text("Default").tag("")

                    ForEach(browser.awsProfiles, id: \.self) { profile in
                        Text(profile).tag(profile)
                    }
                }
                .pickerStyle(.menu)
            }

            HStack {
                Spacer()

                Button("Cancel") {
                    browser.cancelConnectServerDialog()
                }
                .keyboardShortcut(.cancelAction)

                Button("Connect") {
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
        Button(location.isUnavailable ? "Reconnect" : "Open") {
            browser.open(location)
        }

        Divider()

        Button("Open in Terminal") {
            browser.openInTerminal(location.url)
        }
        .disabled(location.isUnavailable || S3Client.isS3URL(location.url))

        Button("Open in iTerm") {
            browser.openIniTerm(location.url)
        }
        .disabled(!browser.isITermAvailable || location.isUnavailable || S3Client.isS3URL(location.url))

        Divider()

        Button("Copy Path") {
            browser.copyPath(location.url)
        }
        .disabled(location.isUnavailable)

        Button("Reveal in Finder") {
            browser.revealInFinder(location.url)
        }
        .disabled(location.isUnavailable || SFTPClient.isSFTPURL(location.url) || S3Client.isS3URL(location.url))

        if location.canDisconnect {
            Divider()

            Button("Disconnect") {
                browser.disconnect(location)
            }
        }

        if location.canRemoveFromFavorites {
            Divider()

            Button("Remove from Favorites") {
                browser.removeFavorite(location)
            }
        }
    }
}

struct StatusBarView: View {
    @EnvironmentObject private var browser: FileBrowserViewModel

    var body: some View {
        HStack(spacing: 12) {
            Text("\(browser.items.count) items")

            if !browser.selectedIDs.isEmpty {
                Text("\(browser.selectedIDs.count) selected")
            }

            if let operation = browser.pendingClipboardOperation {
                Text(operation.mode == .cut ? "Cut ready" : "Copy ready")
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
            Text("Rename")
                .font(.headline)

            TextField("Name", text: $name)
                .textFieldStyle(.roundedBorder)
                .focused($isFocused)
                .onSubmit {
                    onCommit(name)
                }

            HStack {
                Spacer()

                Button("Cancel") {
                    onCancel()
                }
                .keyboardShortcut(.cancelAction)

                Button("Rename") {
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
