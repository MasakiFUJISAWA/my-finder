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

    var id: String { rawValue }
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
    static let sftpURL = "dev.masakifujisawa.mihako.sftp-url"

    static let urlDropTypeIdentifiers = [
        sftpURL,
        UTType.fileURL.identifier,
        UTType.url.identifier,
        UTType.plainText.identifier
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
    var mountPath: String?
    var isUnavailable: Bool

    init(
        kind: RemoteConnectionKind = .smb,
        urlString: String,
        displayName: String? = nil,
        mountPath: String?,
        isUnavailable: Bool
    ) {
        self.kind = kind
        self.urlString = urlString
        self.displayName = displayName
        self.mountPath = mountPath
        self.isUnavailable = isUnavailable
    }

    enum CodingKeys: String, CodingKey {
        case kind
        case urlString
        case displayName
        case mountPath
        case isUnavailable
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        kind = try container.decodeIfPresent(RemoteConnectionKind.self, forKey: .kind) ?? .smb
        urlString = try container.decode(String.self, forKey: .urlString)
        displayName = try container.decodeIfPresent(String.self, forKey: .displayName)
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
