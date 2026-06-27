import AppKit
import SwiftUI

@main
struct MihakoApp: App {
    @NSApplicationDelegateAdaptor(MihakoApplicationDelegate.self) private var appDelegate

    init() {
        NSApplication.shared.setActivationPolicy(.regular)
        AppAppearance.applySavedMode()

        if let iconImage = AppIconLoader.load() {
            NSApplication.shared.applicationIconImage = iconImage
        }

        DispatchQueue.main.async {
            NSApplication.shared.activate(ignoringOtherApps: true)
        }
    }

    var body: some Scene {
        WindowGroup("Mihako", id: "browser") {
            BrowserWindowView()
        }
        .commands {
            BrowserCommands()
        }
    }
}

struct BrowserWindowView: View {
    @Environment(\.openWindow) private var openWindow
    @StateObject private var browser = FileBrowserViewModel()

    var body: some View {
        ContentView()
            .environmentObject(browser)
            .focusedSceneValue(\.fileBrowser, browser)
            .onAppear {
                MihakoApplicationDelegate.openNewWindow = {
                    openWindow(id: "browser")
                }
                ExternalOpenRouter.configure {
                    openWindow(id: "browser")
                }

                AppMenuLocalizer.apply()

                DispatchQueue.main.async {
                    AppMenuLocalizer.apply()
                }

                if let pendingURL = ExternalOpenRouter.consumeNextPendingURL() {
                    browser.openExternalDestination(pendingURL)
                }
            }
    }
}

@MainActor
final class MihakoApplicationDelegate: NSObject, NSApplicationDelegate {
    static var openNewWindow: (() -> Void)?

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppMenuLocalizer.apply()

        DispatchQueue.main.async {
            AppMenuLocalizer.apply()
        }
    }

    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        let menu = NSMenu()
        addDockItem(
            title: L10n.string("New Window"),
            action: #selector(openNewWindowFromDock(_:)),
            to: menu
        )

        menu.addItem(.separator())

        addDockFolderItem(
            title: L10n.string("New Window (Desktop)"),
            url: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop", isDirectory: true),
            to: menu
        )
        addDockFolderItem(
            title: L10n.string("New Window (Downloads)"),
            url: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads", isDirectory: true),
            to: menu
        )

        let shortcuts = LauncherFolderShortcutStore.load()

        if !shortcuts.isEmpty {
            menu.addItem(.separator())

            for shortcut in shortcuts {
                addDockFolderItem(
                    title: shortcut.title,
                    url: shortcut.url,
                    to: menu
                )
            }
        }

        return menu
    }

    @objc private func openNewWindowFromDock(_ sender: Any?) {
        Self.openNewWindow?()
    }

    @objc private func openFolderFromDock(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else {
            return
        }

        ExternalOpenRouter.enqueue([url])
    }

    private func addDockItem(title: String, action: Selector, to menu: NSMenu) {
        let item = NSMenuItem(
            title: title,
            action: action,
            keyEquivalent: ""
        )
        item.target = self
        menu.addItem(item)
    }

    private func addDockFolderItem(title: String, url: URL, to menu: NSMenu) {
        let item = NSMenuItem(
            title: title,
            action: #selector(openFolderFromDock(_:)),
            keyEquivalent: ""
        )
        item.target = self
        item.representedObject = url
        menu.addItem(item)
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        ExternalOpenRouter.enqueue(urls)
    }

    func application(_ sender: NSApplication, openFile filename: String) -> Bool {
        ExternalOpenRouter.enqueue([URL(fileURLWithPath: filename)])
        return true
    }

    func application(_ sender: NSApplication, openFiles filenames: [String]) {
        ExternalOpenRouter.enqueue(filenames.map { URL(fileURLWithPath: $0) })
        sender.reply(toOpenOrPrint: .success)
    }
}

struct FileBrowserFocusedValueKey: FocusedValueKey {
    typealias Value = FileBrowserViewModel
}

extension FocusedValues {
    var fileBrowser: FileBrowserViewModel? {
        get { self[FileBrowserFocusedValueKey.self] }
        set { self[FileBrowserFocusedValueKey.self] = newValue }
    }
}

enum AppIconLoader {
    static func load() -> NSImage? {
        let candidateURLs = [
            Bundle.module.url(forResource: "AppIcon", withExtension: "icns"),
            Bundle.main.url(forResource: "AppIcon", withExtension: "icns")
        ]

        for url in candidateURLs.compactMap({ $0 }) {
            if let image = NSImage(contentsOf: url) {
                return image
            }
        }

        return nil
    }
}

@MainActor
struct BrowserCommands: Commands {
    @Environment(\.openWindow) private var openWindow
    @FocusedValue(\.fileBrowser) private var browser

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button(L10n.string("New Window")) {
                openWindow(id: "browser")
            }
            .keyboardShortcut("n", modifiers: [.command])

            Button(L10n.string("New Folder")) {
                browser?.createFolder()
            }
            .keyboardShortcut("n", modifiers: [.command, .shift])
            .disabled(browser == nil)

            Divider()

            Button(L10n.string("Open")) {
                browser?.openSelected()
            }
            .keyboardShortcut(.return, modifiers: [])
            .disabled(browser?.selectedIDs.isEmpty ?? true)

            Button(L10n.string("Rename")) {
                browser?.beginRenameSelected()
            }
            .keyboardShortcut(.return, modifiers: [.command])
            .disabled((browser?.selectedIDs.count ?? 0) != 1)

            Divider()

            Button(L10n.string("Move to Trash")) {
                browser?.trashSelection()
            }
            .keyboardShortcut(.delete, modifiers: [.command])
            .disabled(browser?.selectedIDs.isEmpty ?? true)
        }

        CommandGroup(replacing: .pasteboard) {
            Button(L10n.string("Cut")) {
                browser?.handleFileCutShortcut()
            }
            .keyboardShortcut("x", modifiers: [.command])
            .disabled(browser == nil)

            Button(L10n.string("Copy")) {
                browser?.handleFileCopyShortcut()
            }
            .keyboardShortcut("c", modifiers: [.command])
            .disabled(browser == nil)

            Button(L10n.string("Paste")) {
                browser?.handleFilePasteShortcut()
            }
            .keyboardShortcut("v", modifiers: [.command])
            .disabled(browser == nil)

            Button(L10n.string("Select All")) {
                browser?.handleSelectAllShortcut()
            }
            .keyboardShortcut("a", modifiers: [.command])
            .disabled(browser == nil)
        }

        CommandGroup(after: .appSettings) {
            Button(L10n.string("Launcher Folders...")) {
                browser?.showLauncherFoldersSettings()
            }
            .disabled(browser == nil)

            Button(L10n.string("External Tools...")) {
                browser?.showExternalToolsSettings()
            }
            .disabled(browser == nil)

            Divider()

            Menu(L10n.string("Appearance")) {
                ForEach(AppAppearanceMode.allCases) { mode in
                    Button(L10n.string(mode.titleKey)) {
                        browser?.setAppAppearanceMode(mode)
                    }
                    .disabled(browser == nil || browser?.appAppearanceMode == mode)
                }
            }

            Divider()

            Menu(L10n.string("Language")) {
                ForEach(AppLanguageMode.allCases) { mode in
                    Button(L10n.string(mode.titleKey)) {
                        browser?.setAppLanguageMode(mode)
                    }
                    .disabled(browser == nil || browser?.appLanguageMode == mode)
                }
            }
        }
    }
}
