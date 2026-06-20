import AppKit
import SwiftUI

@main
struct MyFinderApp: App {
    @StateObject private var browser = FileBrowserViewModel()

    init() {
        NSApplication.shared.setActivationPolicy(.regular)

        if let iconImage = AppIconLoader.load() {
            NSApplication.shared.applicationIconImage = iconImage
        }

        DispatchQueue.main.async {
            NSApplication.shared.activate(ignoringOtherApps: true)
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(browser)
        }
        .commands {
            BrowserCommands(browser: browser)
        }
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
    @ObservedObject var browser: FileBrowserViewModel

    var body: some Commands {
        CommandGroup(after: .newItem) {
            Button("New Folder") {
                browser.createFolder()
            }
            .keyboardShortcut("n", modifiers: [.command, .shift])
        }

        CommandMenu("Files") {
            Button("Open") {
                browser.openSelected()
            }
            .keyboardShortcut(.return, modifiers: [])
            .disabled(browser.selectedIDs.isEmpty)

            Button("Rename") {
                browser.beginRenameSelected()
            }
            .keyboardShortcut(.return, modifiers: [.command])
            .disabled(browser.selectedIDs.count != 1)

            Divider()

            Button("Move to Trash") {
                browser.trashSelection()
            }
            .keyboardShortcut(.delete, modifiers: [.command])
            .disabled(browser.selectedIDs.isEmpty)
        }
    }
}
