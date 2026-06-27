import Foundation
import UniformTypeIdentifiers

enum FileSortColumn: String, CaseIterable {
    case name
    case modifiedAt
    case size
    case kind
}

enum BrowserViewMode: String, CaseIterable, Identifiable {
    case list
    case icons
    case columns
    case gallery

    var id: String { rawValue }
}

enum BrowserContentMode: String, CaseIterable, Identifiable {
    case folder
    case search

    var id: String { rawValue }
}

enum FileGroupMode: String, CaseIterable, Identifiable {
    case none
    case kind
    case modifiedDate
    case size

    var id: String { rawValue }

    var titleKey: String {
        switch self {
        case .none:
            return "None"
        case .kind:
            return "Kind"
        case .modifiedDate:
            return "Date Modified"
        case .size:
            return "Size"
        }
    }
}

enum ArchiveFormat: String, CaseIterable, Identifiable {
    case zip
    case tar
    case tarGzip
    case tarBzip2
    case tarXz

    var id: String { rawValue }

    var titleKey: String {
        switch self {
        case .zip:
            return "ZIP Archive"
        case .tar:
            return "TAR Archive"
        case .tarGzip:
            return "TAR.GZ Archive"
        case .tarBzip2:
            return "TAR.BZ2 Archive"
        case .tarXz:
            return "TAR.XZ Archive"
        }
    }

    var fileExtension: String {
        switch self {
        case .zip:
            return "zip"
        case .tar:
            return "tar"
        case .tarGzip:
            return "tar.gz"
        case .tarBzip2:
            return "tar.bz2"
        case .tarXz:
            return "tar.xz"
        }
    }

    var knownExtensions: [String] {
        switch self {
        case .zip:
            return ["zip"]
        case .tar:
            return ["tar"]
        case .tarGzip:
            return ["tar.gz", "tgz"]
        case .tarBzip2:
            return ["tar.bz2", "tbz2", "tbz"]
        case .tarXz:
            return ["tar.xz", "txz"]
        }
    }

    static func format(for url: URL) -> ArchiveFormat? {
        let filename = url.lastPathComponent.lowercased()

        return allCases.first { format in
            format.knownExtensions.contains { filename.hasSuffix(".\($0)") }
        }
    }
}

struct FileItemGroup: Identifiable {
    let id: String
    let title: String
    let items: [FileItem]
}

enum FileClipboardMode {
    case copy
    case cut
}

struct FileClipboardOperation {
    let mode: FileClipboardMode
    let urls: [URL]
}

struct RenameRequest: Identifiable {
    let id = UUID()
    let url: URL
    let currentName: String
}

enum MihakoTransferType {
    static let fileURLs = "dev.masakifujisawa.mihako.file-urls"
    static let sftpURL = "dev.masakifujisawa.mihako.sftp-url"
    static let s3URL = "dev.masakifujisawa.mihako.s3-url"
    static let filenamesPasteboard = "NSFilenamesPboardType"

    static let urlDropTypeIdentifiers = [
        fileURLs,
        sftpURL,
        s3URL,
        UTType.fileURL.identifier,
        UTType.url.identifier,
        filenamesPasteboard
    ]
}

enum RemoteConnectionKind: String, CaseIterable, Codable, Hashable, Identifiable {
    case smb
    case sftp
    case ftp
    case s3

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .smb:
            return "SMB"
        case .sftp:
            return "SFTP"
        case .ftp:
            return "FTP"
        case .s3:
            return "S3"
        }
    }

    var defaultAddress: String {
        switch self {
        case .smb:
            return "smb://"
        case .sftp:
            return "sftp://"
        case .ftp:
            return "ftp://"
        case .s3:
            return "s3://"
        }
    }

    var placeholder: String {
        switch self {
        case .smb:
            return "smb://server/share"
        case .sftp:
            return "sftp://user@server/path"
        case .ftp:
            return "ftp://user@server/path"
        case .s3:
            return "s3://bucket/prefix"
        }
    }

    var systemImageName: String {
        switch self {
        case .smb:
            return "network"
        case .sftp:
            return "terminal"
        case .ftp:
            return "server.rack"
        case .s3:
            return "shippingbox"
        }
    }

    var defaultPort: Int? {
        switch self {
        case .smb:
            return nil
        case .sftp:
            return 22
        case .ftp:
            return 21
        case .s3:
            return nil
        }
    }

    var canMountThroughSystem: Bool {
        self == .smb
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}

enum ExternalToolKind: String, CaseIterable, Codable, Hashable, Identifiable {
    case terminal
    case iTerm
    case application

    var id: String { rawValue }

    var titleKey: String {
        switch self {
        case .terminal:
            return "Terminal"
        case .iTerm:
            return "iTerm"
        case .application:
            return "Application"
        }
    }
}

enum ExternalToolTarget: String, CaseIterable, Codable, Hashable, Identifiable {
    case currentFolder
    case selectedFolder

    var id: String { rawValue }

    var titleKey: String {
        switch self {
        case .currentFolder:
            return "Current Folder"
        case .selectedFolder:
            return "Selected Folder"
        }
    }
}

enum ExternalToolIconMode: String, CaseIterable, Codable, Hashable, Identifiable {
    case applicationIcon
    case symbol

    var id: String { rawValue }

    var titleKey: String {
        switch self {
        case .applicationIcon:
            return "Application Icon"
        case .symbol:
            return "SF Symbol"
        }
    }
}

struct ExternalTool: Identifiable, Codable, Hashable {
    var id: UUID
    var title: String
    var systemImageName: String
    var iconMode: ExternalToolIconMode
    var kind: ExternalToolKind
    var target: ExternalToolTarget
    var bundleIdentifiers: [String]
    var applicationPath: String?

    init(
        id: UUID = UUID(),
        title: String,
        systemImageName: String,
        iconMode: ExternalToolIconMode = .applicationIcon,
        kind: ExternalToolKind,
        target: ExternalToolTarget,
        bundleIdentifiers: [String] = [],
        applicationPath: String? = nil
    ) {
        self.id = id
        self.title = title
        self.systemImageName = systemImageName
        self.iconMode = iconMode
        self.kind = kind
        self.target = target
        self.bundleIdentifiers = bundleIdentifiers
        self.applicationPath = applicationPath
    }

    enum CodingKeys: String, CodingKey {
        case id
        case title
        case systemImageName
        case iconMode
        case kind
        case target
        case bundleIdentifiers
        case applicationPath
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        title = try container.decode(String.self, forKey: .title)
        systemImageName = try container.decode(String.self, forKey: .systemImageName)
        iconMode = try container.decodeIfPresent(ExternalToolIconMode.self, forKey: .iconMode) ?? .applicationIcon
        kind = try container.decode(ExternalToolKind.self, forKey: .kind)
        target = try container.decode(ExternalToolTarget.self, forKey: .target)
        bundleIdentifiers = try container.decodeIfPresent([String].self, forKey: .bundleIdentifiers) ?? []
        applicationPath = try container.decodeIfPresent(String.self, forKey: .applicationPath)
    }

    var normalized: ExternalTool {
        var copy = self
        copy.title = title.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty ?? L10n.string(kind.titleKey)
        copy.systemImageName = systemImageName.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty ?? "app"
        copy.bundleIdentifiers = bundleIdentifiers
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        copy.applicationPath = applicationPath?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmpty
        return copy
    }

    static let defaultTools: [ExternalTool] = [
        ExternalTool(
            title: "Terminal",
            systemImageName: "terminal",
            iconMode: .applicationIcon,
            kind: .terminal,
            target: .currentFolder
        ),
        ExternalTool(
            title: "iTerm",
            systemImageName: "terminal.fill",
            iconMode: .applicationIcon,
            kind: .iTerm,
            target: .currentFolder
        ),
        ExternalTool(
            title: "WebStorm",
            systemImageName: "globe",
            iconMode: .applicationIcon,
            kind: .application,
            target: .selectedFolder,
            bundleIdentifiers: ["com.jetbrains.WebStorm"]
        ),
        ExternalTool(
            title: "PyCharm",
            systemImageName: "hammer",
            iconMode: .applicationIcon,
            kind: .application,
            target: .selectedFolder,
            bundleIdentifiers: ["com.jetbrains.pycharm", "com.jetbrains.pycharm.ce"]
        ),
        ExternalTool(
            title: "VSCode",
            systemImageName: "chevron.left.forwardslash.chevron.right",
            iconMode: .applicationIcon,
            kind: .application,
            target: .selectedFolder,
            bundleIdentifiers: ["com.microsoft.VSCode", "com.microsoft.VSCodeInsiders"]
        )
    ]
}

struct LauncherFolderShortcut: Identifiable, Codable, Hashable {
    var id: UUID
    var title: String
    var path: String

    init(id: UUID = UUID(), title: String, path: String) {
        self.id = id
        self.title = title
        self.path = path
    }

    var url: URL {
        URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: true)
            .standardizedFileURL
    }

    var normalized: LauncherFolderShortcut {
        let normalizedURL = url
        let fallbackTitle = FileManager.default.displayName(atPath: normalizedURL.path).nilIfEmpty
            ?? normalizedURL.lastPathComponent.nilIfEmpty
            ?? normalizedURL.path
        return LauncherFolderShortcut(
            id: id,
            title: title.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty ?? fallbackTitle,
            path: normalizedURL.path
        )
    }
}

enum LauncherFolderShortcutStore {
    private static let defaultsKey = "Mihako.launcherFolderShortcuts"

    static func load() -> [LauncherFolderShortcut] {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey),
              let shortcuts = try? JSONDecoder().decode([LauncherFolderShortcut].self, from: data) else {
            return []
        }

        return shortcuts.map(\.normalized)
    }

    static func save(_ shortcuts: [LauncherFolderShortcut]) {
        guard let data = try? JSONEncoder().encode(shortcuts.map(\.normalized)) else {
            return
        }

        UserDefaults.standard.set(data, forKey: defaultsKey)
    }
}

struct SidebarLocation: Identifiable, Hashable {
    var id: String {
        connectionURL?.absoluteString ?? url.standardizedFileURL.path
    }

    let title: String
    let systemImageName: String
    let url: URL
    let connectionURL: URL?
    let isUnavailable: Bool
    let canRemoveFromFavorites: Bool
    let canDisconnect: Bool

    init(
        title: String,
        systemImageName: String,
        url: URL,
        connectionURL: URL? = nil,
        isUnavailable: Bool = false,
        canRemoveFromFavorites: Bool = false,
        canDisconnect: Bool = false
    ) {
        self.title = title
        self.systemImageName = systemImageName
        self.url = url
        self.connectionURL = connectionURL
        self.isUnavailable = isUnavailable
        self.canRemoveFromFavorites = canRemoveFromFavorites
        self.canDisconnect = canDisconnect
    }
}

struct ServerConnection: Codable, Hashable {
    var kind: RemoteConnectionKind
    var urlString: String
    var displayName: String?
    var awsProfile: String?
    var mountPath: String?
    var isUnavailable: Bool

    init(
        kind: RemoteConnectionKind = .smb,
        urlString: String,
        displayName: String? = nil,
        awsProfile: String? = nil,
        mountPath: String?,
        isUnavailable: Bool
    ) {
        self.kind = kind
        self.urlString = urlString
        self.displayName = displayName
        self.awsProfile = awsProfile
        self.mountPath = mountPath
        self.isUnavailable = isUnavailable
    }

    enum CodingKeys: String, CodingKey {
        case kind
        case urlString
        case displayName
        case awsProfile
        case mountPath
        case isUnavailable
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        kind = try container.decodeIfPresent(RemoteConnectionKind.self, forKey: .kind) ?? .smb
        urlString = try container.decode(String.self, forKey: .urlString)
        displayName = try container.decodeIfPresent(String.self, forKey: .displayName)
        awsProfile = try container.decodeIfPresent(String.self, forKey: .awsProfile)
        mountPath = try container.decodeIfPresent(String.self, forKey: .mountPath)
        isUnavailable = try container.decode(Bool.self, forKey: .isUnavailable)
    }
}

struct SidebarSection: Identifiable, Hashable {
    var id: String { title }

    let title: String
    let locations: [SidebarLocation]
}

struct Breadcrumb: Identifiable, Hashable {
    var id: String { url.path }

    let title: String
    let url: URL
}

struct FileItem: Identifiable, Hashable, Sendable {
    var id: URL { url }

    let url: URL
    let name: String
    let isDirectory: Bool
    let isPackage: Bool
    let size: Int64?
    let modifiedAt: Date?
    let kind: String
    let isHidden: Bool

    var canNavigateInto: Bool {
        isDirectory && !isPackage
    }

    var displayName: String {
        name.isEmpty ? url.lastPathComponent : name
    }

    var systemImageName: String {
        if isPackage {
            return "shippingbox"
        }

        if isDirectory {
            return "folder"
        }

        switch url.pathExtension.lowercased() {
        case "pdf":
            return "doc.richtext"
        case "jpg", "jpeg", "png", "gif", "heic", "tiff", "webp":
            return "photo"
        case "mov", "mp4", "m4v", "avi":
            return "film"
        case "mp3", "m4a", "wav", "aiff":
            return "music.note"
        case "zip", "gz", "tar", "rar", "7z":
            return "archivebox"
        case "swift", "js", "ts", "py", "rb", "go", "rs", "java", "html", "css", "json", "xml", "yaml", "yml":
            return "chevron.left.forwardslash.chevron.right"
        default:
            return "doc"
        }
    }

    var formattedSize: String {
        guard !isDirectory, let size else {
            return ""
        }

        return size.formatted(.byteCount(style: .file))
    }

    var formattedModifiedAt: String {
        guard let modifiedAt else {
            return ""
        }

        return modifiedAt.formatted(date: .abbreviated, time: .shortened)
    }

    static func load(from url: URL) throws -> FileItem {
        let resourceValues = try url.resourceValues(forKeys: [
            .isDirectoryKey,
            .isPackageKey,
            .fileSizeKey,
            .totalFileAllocatedSizeKey,
            .contentModificationDateKey,
            .localizedTypeDescriptionKey,
            .isHiddenKey,
            .localizedNameKey
        ])

        let isDirectory = resourceValues.isDirectory ?? false
        let size = resourceValues.fileSize.map(Int64.init)
            ?? resourceValues.totalFileAllocatedSize.map(Int64.init)

        return FileItem(
            url: url,
            name: resourceValues.localizedName ?? url.lastPathComponent,
            isDirectory: isDirectory,
            isPackage: resourceValues.isPackage ?? false,
            size: size,
            modifiedAt: resourceValues.contentModificationDate,
            kind: resourceValues.localizedTypeDescription ?? (isDirectory ? "Folder" : "File"),
            isHidden: resourceValues.isHidden ?? false
        )
    }
}
