import Foundation

struct ShellResult: Sendable {
    let status: Int32
    let stdout: String
    let stderr: String

    var succeeded: Bool { status == 0 }
}

struct ShellError: LocalizedError {
    let command: String
    let result: ShellResult

    var errorDescription: String? {
        let detail = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        let fallback = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        let message = detail.isEmpty ? fallback : detail
        return message.isEmpty ? "\(command) failed (exit \(result.status))" : message
    }
}

enum Shell {
    /// Runs an executable without a shell and collects its output.
    static func run(
        _ executable: String,
        _ arguments: [String],
        environment: [String: String] = [:],
        input: String? = nil
    ) async throws -> ShellResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments

        var env = ProcessInfo.processInfo.environment
        // GUI apps get a minimal PATH; make sure Homebrew's locations are on it.
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        env.merge(environment) { _, new in new }
        process.environment = env

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        let inPipe = Pipe()
        process.standardInput = input == nil ? FileHandle.nullDevice : inPipe

        return try await withCheckedThrowingContinuation { continuation in
            // Read pipes on background threads so large outputs can't fill the
            // pipe buffer and deadlock the child.
            let group = DispatchGroup()
            nonisolated(unsafe) var outData = Data()
            nonisolated(unsafe) var errData = Data()
            group.enter()
            DispatchQueue.global().async {
                outData = outPipe.fileHandleForReading.readDataToEndOfFile()
                group.leave()
            }
            group.enter()
            DispatchQueue.global().async {
                errData = errPipe.fileHandleForReading.readDataToEndOfFile()
                group.leave()
            }

            process.terminationHandler = { proc in
                group.notify(queue: .global()) {
                    continuation.resume(returning: ShellResult(
                        status: proc.terminationStatus,
                        stdout: String(decoding: outData, as: UTF8.self),
                        stderr: String(decoding: errData, as: UTF8.self)
                    ))
                }
            }

            do {
                try process.run()
                if let input {
                    inPipe.fileHandleForWriting.write(Data(input.utf8))
                    try? inPipe.fileHandleForWriting.close()
                }
            } catch {
                try? outPipe.fileHandleForWriting.close()
                try? errPipe.fileHandleForWriting.close()
                continuation.resume(throwing: error)
            }
        }
    }

    /// Runs and throws `ShellError` on a non-zero exit.
    @discardableResult
    static func runChecked(
        _ executable: String,
        _ arguments: [String],
        environment: [String: String] = [:],
        input: String? = nil
    ) async throws -> ShellResult {
        let result = try await run(executable, arguments, environment: environment, input: input)
        guard result.succeeded else {
            throw ShellError(command: (executable as NSString).lastPathComponent, result: result)
        }
        return result
    }

    /// Finds a tool in the usual Homebrew locations.
    static func findTool(_ name: String) -> String? {
        ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin"]
            .map { "\($0)/\(name)" }
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }
}
