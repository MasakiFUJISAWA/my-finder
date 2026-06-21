import Foundation

struct S3ConnectionSpec: Sendable {
    let bucket: String
    let prefix: String
    let profile: String?
}

enum S3ClientError: Error, LocalizedError {
    case invalidURL(URL)
    case commandFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidURL(let url):
            return "Invalid S3 URL: \(url.absoluteString)"
        case .commandFailed(let message):
            return message
        }
    }
}

enum S3Client {
    private static let profileQueryName = "awsProfile"

    private struct ProcessResult: Sendable {
        let status: Int32
        let output: Data
        let errorOutput: Data

        var outputString: String {
            String(data: output, encoding: .utf8) ?? ""
        }

        var errorString: String {
            String(data: errorOutput, encoding: .utf8) ?? ""
        }
    }

    private struct ListResponse: Decodable {
        let contents: [Object]?
        let commonPrefixes: [Prefix]?
        let isTruncated: Bool?
        let nextContinuationToken: String?

        enum CodingKeys: String, CodingKey {
            case contents = "Contents"
            case commonPrefixes = "CommonPrefixes"
            case isTruncated = "IsTruncated"
            case nextContinuationToken = "NextContinuationToken"
        }
    }

    private struct Object: Decodable {
        let key: String
        let lastModified: String?
        let size: Int64?

        enum CodingKeys: String, CodingKey {
            case key = "Key"
            case lastModified = "LastModified"
            case size = "Size"
        }
    }

    private struct Prefix: Decodable {
        let prefix: String

        enum CodingKeys: String, CodingKey {
            case prefix = "Prefix"
        }
    }

    static func isS3URL(_ url: URL) -> Bool {
        url.scheme?.lowercased() == "s3"
    }

    static func availableProfiles() async throws -> [String] {
        let result = try await runAWS(["configure", "list-profiles"])
        return result.outputString
            .split(whereSeparator: \.isNewline)
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    static func displayString(for url: URL) -> String {
        let displayURL = urlByRemovingProfile(from: url)
        return displayURL.absoluteString.removingPercentEncoding ?? displayURL.absoluteString
    }

    static func url(bySettingPrefix prefix: String, on url: URL) -> URL {
        guard let bucket = url.host(percentEncoded: false) else {
            return url
        }

        return Self.url(bucket: bucket, prefix: prefix, profile: profile(for: url))
    }

    static func url(bySettingProfile profile: String?, on url: URL) -> URL {
        guard let bucket = url.host(percentEncoded: false) else {
            return url
        }

        return Self.url(bucket: bucket, prefix: prefix(for: url), profile: profile)
    }

    static func url(bucket: String, prefix: String, profile: String? = nil) -> URL {
        var components = URLComponents()
        components.scheme = "s3"
        components.host = bucket
        components.path = normalizedPath(for: prefix)
        components.queryItems = profile
            .flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty }
            .map { [URLQueryItem(name: profileQueryName, value: $0)] }
        return components.url ?? URL(string: "s3://\(bucket)/")!
    }

    static func childURL(named name: String, isDirectory: Bool, in directoryURL: URL) -> URL {
        let childPrefix = appendingPrefixComponent(name, to: directoryPrefix(for: directoryURL))
        return url(
            bySettingPrefix: isDirectory ? directoryPrefix(childPrefix) : childPrefix,
            on: directoryURL
        )
    }

    static func parentURL(for url: URL) -> URL {
        let prefix = prefix(for: url).trimmingTrailingSlash

        guard !prefix.isEmpty else {
            return Self.url(bySettingPrefix: "", on: url)
        }

        let parentPrefix = (prefix as NSString).deletingLastPathComponent
        return Self.url(bySettingPrefix: parentPrefix.isEmpty ? "" : directoryPrefix(parentPrefix), on: url)
    }

    static func prefix(for url: URL) -> String {
        var rawPath = url.path.removingPercentEncoding ?? url.path

        while rawPath.hasPrefix("/") {
            rawPath.removeFirst()
        }

        return rawPath
    }

    static func profile(for url: URL) -> String? {
        URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?
            .first { $0.name == profileQueryName }?
            .value?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmpty
    }

    static func directoryPrefix(for url: URL) -> String {
        directoryPrefix(prefix(for: url))
    }

    static func resolvedDirectoryURL(for url: URL) throws -> URL {
        let spec = try connectionSpec(for: url)
        return Self.url(bucket: spec.bucket, prefix: directoryPrefix(spec.prefix), profile: spec.profile)
    }

    static func listDirectory(at url: URL, showHiddenFiles: Bool) async throws -> (url: URL, items: [FileItem]) {
        let resolvedURL = try resolvedDirectoryURL(for: url)
        let spec = try connectionSpec(for: resolvedURL)
        var items: [FileItem] = []
        var seenNames: Set<String> = []
        var continuationToken: String?

        repeat {
            var arguments = [
                "s3api", "list-objects-v2",
                "--bucket", spec.bucket,
                "--delimiter", "/",
                "--output", "json"
            ]

            if !spec.prefix.isEmpty {
                arguments.append(contentsOf: ["--prefix", spec.prefix])
            }

            if let continuationToken {
                arguments.append(contentsOf: ["--continuation-token", continuationToken])
            }

            let result = try await runAWS(arguments, profile: spec.profile)
            let response = try JSONDecoder().decode(ListResponse.self, from: result.output)

            for commonPrefix in response.commonPrefixes ?? [] {
                let name = displayName(forKey: commonPrefix.prefix, parentPrefix: spec.prefix)

                guard !name.isEmpty,
                      seenNames.insert(name).inserted,
                      showHiddenFiles || !name.hasPrefix(".") else {
                    continue
                }

                items.append(
                    FileItem(
                        url: Self.url(bucket: spec.bucket, prefix: commonPrefix.prefix, profile: spec.profile),
                        name: name,
                        isDirectory: true,
                        isPackage: false,
                        size: nil,
                        modifiedAt: nil,
                        kind: "Folder",
                        isHidden: name.hasPrefix(".")
                    )
                )
            }

            for object in response.contents ?? [] {
                guard object.key != spec.prefix else {
                    continue
                }

                let name = displayName(forKey: object.key, parentPrefix: spec.prefix)
                let isDirectory = object.key.hasSuffix("/")

                guard !name.isEmpty,
                      !name.contains("/"),
                      seenNames.insert(name).inserted,
                      showHiddenFiles || !name.hasPrefix(".") else {
                    continue
                }

                items.append(
                    FileItem(
                        url: Self.url(bucket: spec.bucket, prefix: object.key, profile: spec.profile),
                        name: name,
                        isDirectory: isDirectory,
                        isPackage: false,
                        size: isDirectory ? nil : object.size,
                        modifiedAt: object.lastModified.flatMap(parseDate),
                        kind: isDirectory ? "Folder" : "File",
                        isHidden: name.hasPrefix(".")
                    )
                )
            }

            continuationToken = response.isTruncated == true
                ? response.nextContinuationToken
                : nil
        } while continuationToken != nil

        return (resolvedURL, items)
    }

    static func upload(localURLs: [URL], to remoteDirectoryURL: URL) async throws {
        guard !localURLs.isEmpty else {
            return
        }

        let spec = try connectionSpec(for: remoteDirectoryURL)

        for localURL in localURLs {
            let isDirectory = isLocalDirectory(localURL)
            let destinationURL = childURL(
                named: localURL.lastPathComponent,
                isDirectory: isDirectory,
                in: remoteDirectoryURL
            )
            var arguments = ["s3", "cp", localURL.path, uri(for: destinationURL)]

            if isDirectory {
                arguments.append("--recursive")
            }

            _ = try await runAWS(arguments, profile: spec.profile)
        }
    }

    static func download(remoteURLs: [URL], to localDirectoryURL: URL) async throws {
        guard !remoteURLs.isEmpty else {
            return
        }

        try FileManager.default.createDirectory(
            at: localDirectoryURL,
            withIntermediateDirectories: true
        )

        for remoteURL in remoteURLs {
            let spec = try connectionSpec(for: remoteURL)
            let isDirectory = isDirectoryURL(remoteURL)
            let destinationURL = localDirectoryURL.appendingPathComponent(displayName(for: remoteURL))
            var arguments = ["s3", "cp", uri(for: remoteURL), destinationURL.path]

            if isDirectory {
                arguments.append("--recursive")
            }

            _ = try await runAWS(arguments, profile: spec.profile)
        }
    }

    static func createDirectory(at url: URL) async throws {
        let spec = try connectionSpec(for: url)
        _ = try await runAWS([
            "s3api", "put-object",
            "--bucket", spec.bucket,
            "--key", directoryPrefix(spec.prefix),
            "--body", "/dev/null"
        ], profile: spec.profile)
    }

    static func createFile(at url: URL) async throws {
        let spec = try connectionSpec(for: url)
        _ = try await runAWS([
            "s3api", "put-object",
            "--bucket", spec.bucket,
            "--key", spec.prefix,
            "--body", "/dev/null"
        ], profile: spec.profile)
    }

    static func rename(from sourceURL: URL, to destinationURL: URL) async throws {
        try await copy(from: sourceURL, to: destinationURL)
        try await remove([sourceURL])
    }

    static func duplicate(from sourceURL: URL, to destinationURL: URL) async throws {
        try await copy(from: sourceURL, to: destinationURL)
    }

    static func copy(from sourceURL: URL, to destinationURL: URL) async throws {
        let spec = try connectionSpec(for: sourceURL)
        var arguments = ["s3", "cp", uri(for: sourceURL), uri(for: destinationURL)]

        if isDirectoryURL(sourceURL) {
            try await createDirectory(at: destinationURL)
            arguments.append("--recursive")
        }

        _ = try await runAWS(arguments, profile: spec.profile)
    }

    static func remove(_ urls: [URL]) async throws {
        for url in urls {
            let spec = try connectionSpec(for: url)
            var arguments = ["s3", "rm", uri(for: url)]

            if isDirectoryURL(url) {
                arguments.append("--recursive")
            }

            _ = try await runAWS(arguments, profile: spec.profile)
        }
    }

    static func connectionSpec(for url: URL) throws -> S3ConnectionSpec {
        guard isS3URL(url), let bucket = url.host(percentEncoded: false), !bucket.isEmpty else {
            throw S3ClientError.invalidURL(url)
        }

        return S3ConnectionSpec(bucket: bucket, prefix: prefix(for: url), profile: profile(for: url))
    }

    private static func runAWS(_ arguments: [String], profile: String? = nil) async throws -> ProcessResult {
        let command = awsCommand()
        let profileArguments = profile.map { ["--profile", $0] } ?? []
        return try await run(command.executable, arguments: command.arguments + profileArguments + arguments)
    }

    private static func run(_ executable: String, arguments: [String]) async throws -> ProcessResult {
        try await Task.detached(priority: .userInitiated) {
            let process = Process()
            let outputPipe = Pipe()
            let errorPipe = Pipe()

            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            process.standardOutput = outputPipe
            process.standardError = errorPipe

            try process.run()
            process.waitUntilExit()

            let output = outputPipe.fileHandleForReading.readDataToEndOfFile()
            let errorOutput = errorPipe.fileHandleForReading.readDataToEndOfFile()
            let result = ProcessResult(
                status: process.terminationStatus,
                output: output,
                errorOutput: errorOutput
            )

            guard result.status == 0 else {
                let message = result.errorString.trimmingCharacters(in: .whitespacesAndNewlines)
                    .nilIfEmpty
                    ?? result.outputString.trimmingCharacters(in: .whitespacesAndNewlines)
                    .nilIfEmpty
                    ?? "AWS command failed with status \(result.status)."

                throw S3ClientError.commandFailed(message)
            }

            return result
        }.value
    }

    private static func awsCommand() -> (executable: String, arguments: [String]) {
        let candidates = [
            "/opt/homebrew/bin/aws",
            "/usr/local/bin/aws",
            "/usr/bin/aws"
        ]

        for candidate in candidates where FileManager.default.isExecutableFile(atPath: candidate) {
            return (candidate, [])
        }

        return ("/usr/bin/env", ["aws"])
    }

    private static func uri(for url: URL) -> String {
        guard let bucket = url.host(percentEncoded: false) else {
            return displayString(for: url)
        }

        let prefix = prefix(for: url)
        return prefix.isEmpty ? "s3://\(bucket)" : "s3://\(bucket)/\(prefix)"
    }

    private static func urlByRemovingProfile(from url: URL) -> URL {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let queryItems = components.queryItems else {
            return url
        }

        let visibleQueryItems = queryItems.filter { $0.name != profileQueryName }
        components.queryItems = visibleQueryItems.isEmpty ? nil : visibleQueryItems
        return components.url ?? url
    }

    private static func displayName(for url: URL) -> String {
        displayName(forKey: prefix(for: url), parentPrefix: directoryPrefix(for: parentURL(for: url)))
    }

    private static func displayName(forKey key: String, parentPrefix: String) -> String {
        let trimmedParent = directoryPrefix(parentPrefix)
        var relativeName = key

        if !trimmedParent.isEmpty, relativeName.hasPrefix(trimmedParent) {
            relativeName.removeFirst(trimmedParent.count)
        }

        return relativeName.trimmingTrailingSlash
    }

    static func isDirectoryURL(_ url: URL) -> Bool {
        prefix(for: url).hasSuffix("/")
    }

    private static func isLocalDirectory(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    private static func parseDate(_ string: String) -> Date? {
        ISO8601DateFormatter().date(from: string)
    }

    private static func normalizedPath(for prefix: String) -> String {
        var trimmedPrefix = prefix

        while trimmedPrefix.hasPrefix("/") {
            trimmedPrefix.removeFirst()
        }

        return trimmedPrefix.isEmpty ? "/" : "/\(trimmedPrefix)"
    }

    private static func directoryPrefix(_ prefix: String) -> String {
        let trimmedPrefix = prefix.trimmingCharacters(in: CharacterSet(charactersIn: "/"))

        guard !trimmedPrefix.isEmpty else {
            return ""
        }

        return "\(trimmedPrefix)/"
    }

    private static func appendingPrefixComponent(_ component: String, to prefix: String) -> String {
        prefix.isEmpty ? component : "\(directoryPrefix(prefix))\(component)"
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }

    var trimmingTrailingSlash: String {
        var result = self

        while result.hasSuffix("/") {
            result.removeLast()
        }

        return result
    }
}
