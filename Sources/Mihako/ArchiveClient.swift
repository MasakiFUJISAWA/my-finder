import Foundation

enum ArchiveClientError: Error, LocalizedError {
    case commandFailed(String)

    var errorDescription: String? {
        switch self {
        case .commandFailed(let message):
            return message
        }
    }
}

enum ArchiveClient {
    static func createArchive(
        format: ArchiveFormat,
        sourceNames: [String],
        parentDirectory: URL,
        destinationURL: URL
    ) async throws {
        guard !sourceNames.isEmpty else {
            return
        }

        switch format {
        case .zip:
            try await run(
                executablePath: "/usr/bin/zip",
                arguments: ["-qry", destinationURL.path] + sourceNames,
                currentDirectoryURL: parentDirectory
            )
        case .tar:
            try await runTarCreate(
                arguments: ["-cf", destinationURL.path] + sourceNames,
                currentDirectoryURL: parentDirectory
            )
        case .tarGzip:
            try await runTarCreate(
                arguments: ["-czf", destinationURL.path] + sourceNames,
                currentDirectoryURL: parentDirectory
            )
        case .tarBzip2:
            try await runTarCreate(
                arguments: ["-cjf", destinationURL.path] + sourceNames,
                currentDirectoryURL: parentDirectory
            )
        case .tarXz:
            try await runTarCreate(
                arguments: ["-cJf", destinationURL.path] + sourceNames,
                currentDirectoryURL: parentDirectory
            )
        }
    }

    static func extractArchive(
        format: ArchiveFormat,
        archiveURL: URL,
        destinationDirectory: URL
    ) async throws {
        try FileManager.default.createDirectory(
            at: destinationDirectory,
            withIntermediateDirectories: true
        )

        switch format {
        case .zip:
            try await run(
                executablePath: "/usr/bin/ditto",
                arguments: ["-x", "-k", archiveURL.path, destinationDirectory.path]
            )
        case .tar, .tarGzip, .tarBzip2, .tarXz:
            try await run(
                executablePath: "/usr/bin/tar",
                arguments: ["-xf", archiveURL.path, "-C", destinationDirectory.path]
            )
        }
    }

    private static func runTarCreate(arguments: [String], currentDirectoryURL: URL) async throws {
        try await run(
            executablePath: "/usr/bin/tar",
            arguments: arguments,
            currentDirectoryURL: currentDirectoryURL
        )
    }

    private static func run(
        executablePath: String,
        arguments: [String],
        currentDirectoryURL: URL? = nil
    ) async throws {
        try await Task.detached(priority: .userInitiated) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executablePath)
            process.arguments = arguments
            process.currentDirectoryURL = currentDirectoryURL

            let outputPipe = Pipe()
            let errorPipe = Pipe()
            process.standardOutput = outputPipe
            process.standardError = errorPipe

            try process.run()
            process.waitUntilExit()

            let output = String(data: outputPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            let errorOutput = String(data: errorPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            let message = [output, errorOutput]
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .joined(separator: "\n")

            guard process.terminationStatus == 0 else {
                throw ArchiveClientError.commandFailed(
                    message.isEmpty
                        ? "Command failed with status \(process.terminationStatus)."
                        : message
                )
            }
        }.value
    }
}
