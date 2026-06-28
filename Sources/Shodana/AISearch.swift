import Foundation
import Security

enum SearchInteractionMode: String, CaseIterable, Identifiable {
    case keyword
    case ai

    var id: String { rawValue }

    var titleKey: String {
        switch self {
        case .keyword:
            return "Keyword Search"
        case .ai:
            return "AI Search"
        }
    }

    var systemImageName: String {
        switch self {
        case .keyword:
            return "magnifyingglass"
        case .ai:
            return "sparkles"
        }
    }
}

struct AIStorageScope: Identifiable, Codable, Hashable, Sendable {
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

    var normalized: AIStorageScope {
        let normalizedURL = url
        let fallbackTitle = FileManager.default.displayName(atPath: normalizedURL.path).aiNilIfEmpty
            ?? normalizedURL.lastPathComponent.aiNilIfEmpty
            ?? normalizedURL.path
        return AIStorageScope(
            id: id,
            title: title.trimmingCharacters(in: .whitespacesAndNewlines).aiNilIfEmpty ?? fallbackTitle,
            path: normalizedURL.path
        )
    }
}

struct AISearchSettings: Codable, Hashable, Sendable {
    var endpointURLString: String
    var model: String
    var scopes: [AIStorageScope]
    var excludedPatternsText: String
    var maxFiles: Int
    var maxFileBytes: Int
    var maxContextCharacters: Int

    static let defaultExcludedPatterns = """
    .git
    node_modules
    dist
    build
    .build
    .DS_Store
    .env
    .env.*
    *.pem
    *.key
    *.p12
    *.mobileprovision
    *.xcuserstate
    *.log
    *.tmp
    *.cache
    """

    static let defaultSettings = AISearchSettings(
        endpointURLString: "https://api.openai.com/v1/chat/completions",
        model: "gpt-4o-mini",
        scopes: [],
        excludedPatternsText: defaultExcludedPatterns,
        maxFiles: 24,
        maxFileBytes: 64 * 1024,
        maxContextCharacters: 28_000
    )

    var normalized: AISearchSettings {
        AISearchSettings(
            endpointURLString: endpointURLString.trimmingCharacters(in: .whitespacesAndNewlines),
            model: model.trimmingCharacters(in: .whitespacesAndNewlines),
            scopes: scopes.map(\.normalized),
            excludedPatternsText: excludedPatternsText,
            maxFiles: max(4, min(maxFiles, 80)),
            maxFileBytes: max(4 * 1024, min(maxFileBytes, 512 * 1024)),
            maxContextCharacters: max(4_000, min(maxContextCharacters, 120_000))
        )
    }

    var excludedPatterns: [String] {
        excludedPatternsText
            .split(whereSeparator: \.isNewline)
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
    }
}

enum AISearchSettingsStore {
    private static let defaultsKey = "Shodana.aiSearchSettings"
    private static let legacyDefaultsKeys = ["Mihako.aiSearchSettings"]

    static func load() -> AISearchSettings {
        guard let data = AppDefaults.migratedData(forKey: defaultsKey, legacyKeys: legacyDefaultsKeys),
              let settings = try? JSONDecoder().decode(AISearchSettings.self, from: data) else {
            return .defaultSettings
        }

        return settings.normalized
    }

    static func save(_ settings: AISearchSettings) {
        guard let data = try? JSONEncoder().encode(settings.normalized) else {
            return
        }

        UserDefaults.standard.set(data, forKey: defaultsKey)
    }
}

enum AIProviderSecretStore {
    private static let service = "dev.masakifujisawa.shodana.ai"
    private static let account = "chat-completions-api-key"

    static func loadAPIKey() -> String? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)

        guard status == errSecSuccess,
              let data = item as? Data,
              let apiKey = String(data: data, encoding: .utf8),
              !apiKey.isEmpty else {
            return nil
        }

        return apiKey
    }

    static func saveAPIKey(_ apiKey: String) {
        let trimmedAPIKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmedAPIKey.isEmpty else {
            deleteAPIKey()
            return
        }

        let data = Data(trimmedAPIKey.utf8)
        var query = baseQuery

        let updateStatus = SecItemUpdate(
            query as CFDictionary,
            [kSecValueData as String: data] as CFDictionary
        )

        if updateStatus == errSecItemNotFound {
            query[kSecValueData as String] = data
            SecItemAdd(query as CFDictionary, nil)
        }
    }

    static func deleteAPIKey() {
        SecItemDelete(baseQuery as CFDictionary)
    }

    private static var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }
}

enum AIChatRole: String, Codable, Hashable, Sendable {
    case user
    case assistant
    case system

    var titleKey: String {
        switch self {
        case .user:
            return "You"
        case .assistant:
            return "AI"
        case .system:
            return "System"
        }
    }
}

struct AIChatMessage: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    let role: AIChatRole
    let content: String
    let createdAt: Date

    init(id: UUID = UUID(), role: AIChatRole, content: String, createdAt: Date = Date()) {
        self.id = id
        self.role = role
        self.content = content
        self.createdAt = createdAt
    }
}

struct AIContextFile: Identifiable, Hashable, Sendable {
    var id: String { url.path }

    let url: URL
    let rootURL: URL
    let relativePath: String
    let snippet: String
    let matchSummary: String
    let size: Int
    let modifiedAt: Date?
    let score: Int
}

struct AIContextBuildResult: Sendable {
    let files: [AIContextFile]
    let scannedFileCount: Int
    let skippedFileCount: Int
}

enum AISearchError: Error, LocalizedError {
    case invalidEndpoint(String)
    case missingProviderConfiguration
    case providerError(String)
    case noReadableContext

    var errorDescription: String? {
        switch self {
        case .invalidEndpoint(let value):
            return "Invalid AI endpoint: \(value)"
        case .missingProviderConfiguration:
            return "AI provider is not configured."
        case .providerError(let message):
            return message
        case .noReadableContext:
            return "No readable files were found in the AI scope."
        }
    }
}

enum AISearchContextBuilder {
    private static let textExtensions: Set<String> = [
        "applescript", "c", "cc", "conf", "cpp", "cs", "css", "csv", "env", "go",
        "h", "hpp", "htm", "html", "java", "js", "json", "jsx", "kt", "kts", "log",
        "m", "markdown", "md", "mm", "php", "plist", "properties", "py", "rb", "rs",
        "sh", "sql", "swift", "toml", "ts", "tsx", "txt", "xml", "yaml", "yml"
    ]

    static func collectContext(
        question: String,
        rootURLs: [URL],
        settings: AISearchSettings
    ) async throws -> AIContextBuildResult {
        let normalizedSettings = settings.normalized
        let roots = rootURLs.map(\.standardizedFileURL)
        let patterns = normalizedSettings.excludedPatterns
        let queryTerms = searchTerms(from: question)

        let worker = Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()

            let keys: [URLResourceKey] = [
                .isDirectoryKey,
                .isPackageKey,
                .isRegularFileKey,
                .fileSizeKey,
                .contentModificationDateKey,
                .isHiddenKey
            ]
            var candidates: [AIContextFile] = []
            var scannedFileCount = 0
            var skippedFileCount = 0

            for rootURL in roots {
                guard FileManager.default.fileExists(atPath: rootURL.path) else {
                    continue
                }

                let enumerator = FileManager.default.enumerator(
                    at: rootURL,
                    includingPropertiesForKeys: keys,
                    options: [.skipsPackageDescendants]
                ) { _, _ in
                    true
                }

                while let url = enumerator?.nextObject() as? URL {
                    try Task.checkCancellation()

                    let relativePath = relativePath(for: url, rootURL: rootURL)
                    let values = try? url.resourceValues(forKeys: Set(keys))
                    let isDirectory = values?.isDirectory == true

                    if isIgnored(relativePath: relativePath, name: url.lastPathComponent, patterns: patterns) {
                        if isDirectory {
                            enumerator?.skipDescendants()
                        }
                        skippedFileCount += 1
                        continue
                    }

                    guard values?.isRegularFile == true else {
                        continue
                    }

                    scannedFileCount += 1

                    guard isLikelyTextFile(url),
                          let size = values?.fileSize,
                          size <= normalizedSettings.maxFileBytes else {
                        skippedFileCount += 1
                        continue
                    }

                    guard let text = readTextPrefix(from: url, maxBytes: normalizedSettings.maxFileBytes) else {
                        skippedFileCount += 1
                        continue
                    }

                    let score = relevanceScore(relativePath: relativePath, text: text, queryTerms: queryTerms)
                    guard score > 0 || candidates.count < normalizedSettings.maxFiles / 2 else {
                        continue
                    }

                    candidates.append(
                        AIContextFile(
                            url: url,
                            rootURL: rootURL,
                            relativePath: relativePath,
                            snippet: snippet(from: text, queryTerms: queryTerms),
                            matchSummary: matchSummary(relativePath: relativePath, text: text, queryTerms: queryTerms),
                            size: size,
                            modifiedAt: values?.contentModificationDate,
                            score: score
                        )
                    )
                }
            }

            let files = candidates
                .sorted { left, right in
                    if left.score == right.score {
                        return left.relativePath.localizedStandardCompare(right.relativePath) == .orderedAscending
                    }

                    return left.score > right.score
                }
                .prefix(normalizedSettings.maxFiles)

            return AIContextBuildResult(
                files: Array(files),
                scannedFileCount: scannedFileCount,
                skippedFileCount: skippedFileCount
            )
        }

        return try await withTaskCancellationHandler {
            try await worker.value
        } onCancel: {
            worker.cancel()
        }
    }

    private static func searchTerms(from question: String) -> [String] {
        let separators = CharacterSet.alphanumerics
            .union(CharacterSet(charactersIn: "_-./"))
            .inverted
        let terms = question
            .components(separatedBy: separators)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { $0.count >= 2 }

        if !terms.isEmpty {
            return Array(Set(terms))
        }

        let normalizedQuestion = question.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalizedQuestion.isEmpty ? [] : [normalizedQuestion]
    }

    private static func relativePath(for url: URL, rootURL: URL) -> String {
        let rootPath = rootURL.path.aiTrimmingTrailingSlash
        let path = url.path

        guard path.hasPrefix(rootPath) else {
            return url.lastPathComponent
        }

        let relative = path.dropFirst(rootPath.count).drop { $0 == "/" }
        return relative.isEmpty ? url.lastPathComponent : String(relative)
    }

    private static func isIgnored(relativePath: String, name: String, patterns: [String]) -> Bool {
        let lowercasedPath = relativePath.lowercased()
        let lowercasedName = name.lowercased()

        return patterns.contains { rawPattern in
            let pattern = rawPattern.lowercased()

            if pattern.hasPrefix("*.") {
                return lowercasedName.hasSuffix(String(pattern.dropFirst()))
            }

            if pattern.hasSuffix("/*") {
                let prefix = String(pattern.dropLast(2))
                return lowercasedPath == prefix || lowercasedPath.hasPrefix(prefix + "/")
            }

            if pattern.contains("/") {
                return lowercasedPath == pattern || lowercasedPath.hasPrefix(pattern + "/")
            }

            return lowercasedName == pattern
                || lowercasedPath.split(separator: "/").contains(Substring(pattern))
        }
    }

    private static func isLikelyTextFile(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        return ext.isEmpty || textExtensions.contains(ext)
    }

    private static func readTextPrefix(from url: URL, maxBytes: Int) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            return nil
        }

        defer {
            try? handle.close()
        }

        let data = handle.readData(ofLength: maxBytes)

        guard !data.isEmpty,
              data.firstIndex(of: 0) == nil else {
            return nil
        }

        return String(data: data, encoding: .utf8)
    }

    private static func relevanceScore(relativePath: String, text: String, queryTerms: [String]) -> Int {
        guard !queryTerms.isEmpty else {
            return 1
        }

        let lowercasedPath = relativePath.lowercased()
        let lowercasedText = text.lowercased()
        var score = 0

        for term in queryTerms {
            if lowercasedPath.contains(term) {
                score += 12
            }

            if lowercasedText.contains(term) {
                score += 4
            }
        }

        return score
    }

    private static func snippet(from text: String, queryTerms: [String]) -> String {
        let normalizedText = text.replacingOccurrences(of: "\r\n", with: "\n")
        let lowercasedText = normalizedText.lowercased()
        let matchRange = queryTerms
            .compactMap { lowercasedText.range(of: $0) }
            .min { $0.lowerBound < $1.lowerBound }

        guard let matchRange else {
            return String(normalizedText.prefix(1_200))
        }

        let start = normalizedText.index(matchRange.lowerBound, offsetBy: -400, limitedBy: normalizedText.startIndex)
            ?? normalizedText.startIndex
        let end = normalizedText.index(matchRange.upperBound, offsetBy: 800, limitedBy: normalizedText.endIndex)
            ?? normalizedText.endIndex

        return String(normalizedText[start..<end])
    }

    private static func matchSummary(relativePath: String, text: String, queryTerms: [String]) -> String {
        guard !queryTerms.isEmpty else {
            return "Context candidate"
        }

        let lowercasedPath = relativePath.lowercased()
        let lowercasedText = text.lowercased()
        var matches: [String] = []

        if queryTerms.contains(where: { lowercasedPath.contains($0) }) {
            matches.append("path")
        }

        if queryTerms.contains(where: { lowercasedText.contains($0) }) {
            matches.append("content")
        }

        return matches.isEmpty ? "context candidate" : "matched " + matches.joined(separator: ", ")
    }
}

private extension String {
    var aiNilIfEmpty: String? {
        isEmpty ? nil : self
    }

    var aiTrimmingTrailingSlash: String {
        var result = self

        while result.hasSuffix("/") {
            result.removeLast()
        }

        return result
    }
}

enum AIChatClient {
    struct ChatMessage: Codable, Sendable {
        let role: String
        let content: String
    }

    private struct RequestBody: Encodable {
        let model: String
        let messages: [ChatMessage]
        let temperature: Double
    }

    private struct ResponseBody: Decodable {
        struct Choice: Decodable {
            struct Message: Decodable {
                let content: String?
            }

            let message: Message?
        }

        struct ErrorBody: Decodable {
            let message: String?
        }

        let choices: [Choice]?
        let error: ErrorBody?
    }

    static func complete(
        settings: AISearchSettings,
        apiKey: String,
        messages: [ChatMessage]
    ) async throws -> String {
        let normalizedSettings = settings.normalized
        let trimmedAPIKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !normalizedSettings.endpointURLString.isEmpty,
              !normalizedSettings.model.isEmpty,
              !trimmedAPIKey.isEmpty else {
            throw AISearchError.missingProviderConfiguration
        }

        guard let endpointURL = URL(string: normalizedSettings.endpointURLString) else {
            throw AISearchError.invalidEndpoint(normalizedSettings.endpointURLString)
        }

        var request = URLRequest(url: endpointURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(trimmedAPIKey)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 120
        request.httpBody = try JSONEncoder().encode(
            RequestBody(
                model: normalizedSettings.model,
                messages: messages,
                temperature: 0.2
            )
        )

        let (data, response) = try await URLSession.shared.data(for: request)
        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
        let decodedResponse = try? JSONDecoder().decode(ResponseBody.self, from: data)

        guard (200..<300).contains(statusCode) else {
            let responseText = decodedResponse?.error?.message
                ?? String(data: data, encoding: .utf8)
                ?? "HTTP \(statusCode)"
            throw AISearchError.providerError(responseText)
        }

        guard let content = decodedResponse?.choices?.first?.message?.content?.trimmingCharacters(in: .whitespacesAndNewlines),
              !content.isEmpty else {
            throw AISearchError.providerError("AI provider returned an empty response.")
        }

        return content
    }
}

enum AISearchPromptBuilder {
    static func messages(
        question: String,
        contextFiles: [AIContextFile],
        previousMessages: [AIChatMessage],
        settings: AISearchSettings
    ) -> [AIChatClient.ChatMessage] {
        let systemPrompt = """
        You are Shodana's AI search assistant. Answer using only the file context explicitly provided by Shodana. If the context is insufficient, say what is missing and suggest which files or folders should be added to the AI scope. Prefer concise, actionable engineering guidance.
        """
        let context = contextText(from: contextFiles, limit: settings.normalized.maxContextCharacters)
        let recentHistory = previousMessages
            .suffix(6)
            .map {
                AIChatClient.ChatMessage(
                    role: $0.role.rawValue,
                    content: $0.content
                )
            }
        let currentQuestion = """
        User question:
        \(question)

        Files disclosed to AI for this turn:
        \(context)
        """

        return [AIChatClient.ChatMessage(role: "system", content: systemPrompt)]
            + recentHistory
            + [AIChatClient.ChatMessage(role: "user", content: currentQuestion)]
    }

    static func contextText(from files: [AIContextFile], limit: Int) -> String {
        guard !files.isEmpty else {
            return "(No files matched the current AI scope and question.)"
        }

        var remainingCharacters = limit
        var chunks: [String] = []

        for file in files {
            guard remainingCharacters > 0 else {
                break
            }

            let header = """

            --- FILE: \(file.relativePath)
            Size: \(file.size) bytes
            Match: \(file.matchSummary)
            ---

            """
            let allowedSnippetCount = max(0, remainingCharacters - header.count)
            let snippet = String(file.snippet.prefix(allowedSnippetCount))
            let chunk = header + snippet
            chunks.append(chunk)
            remainingCharacters -= chunk.count
        }

        return chunks.joined(separator: "\n")
    }
}
