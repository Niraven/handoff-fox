import CryptoKit
import Foundation

enum HostTrust {
    struct Key: Identifiable, Sendable {
        let host: String
        let type: String
        let fingerprint: String
        let line: String
        var id: String { "\(type):\(fingerprint)" }
    }

    enum TrustError: LocalizedError {
        case unresolved(String)
        case none(String)
        case unreadable(String)

        var errorDescription: String? {
            switch self {
            case .unresolved(let address):
                "Could not resolve \(address) from your SSH configuration."
            case .none(let host):
                "No host key answered at \(host). Check that the machine is awake and its SSH server is running."
            case .unreadable(let reason):
                "Could not read your known_hosts file: \(reason)"
            }
        }
    }

    /// Reads the keys the machine presents without trusting them yet, so the
    /// person can compare a fingerprint with the Linux side before pairing.
    static func keys(for address: String, config: URL? = nil) throws -> [Key] {
        let (hostname, port) = try resolve(address, config: config)
        guard !hostname.hasPrefix("-") else { throw TrustError.unresolved(address) }
        let output = try run("/usr/bin/ssh-keyscan",
                             ["-T", "5", "-p", String(port), "-t", "ed25519,ecdsa,rsa", hostname])
        let keys = output.split(whereSeparator: \.isNewline).compactMap(parse)
        guard !keys.isEmpty else { throw TrustError.none(hostname) }
        return keys
    }

    /// Appends the exact lines ssh-keyscan returned. The caller has already shown
    /// the fingerprints and taken a decision; nothing here decides for the user.
    static func trust(_ keys: [Key]) throws {
        guard !keys.isEmpty else { throw TrustError.none("the device") }
        let directory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".ssh", isDirectory: true)
        let file = directory.appendingPathComponent("known_hosts")
        let text = keys.map(\.line).joined(separator: "\n") + "\n"
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            if FileManager.default.fileExists(atPath: file.path) {
                let handle = try FileHandle(forWritingTo: file)
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: Data(text.utf8))
            } else {
                try text.write(to: file, atomically: true, encoding: .utf8)
                try FileManager.default.setAttributes([.posixPermissions: 0o600],
                                                      ofItemAtPath: file.path)
            }
        } catch {
            throw TrustError.unreadable(error.localizedDescription)
        }
    }

    private static func resolve(_ address: String, config: URL?) throws -> (String, Int) {
        let arguments = (config.map { ["-F", $0.path] } ?? []) + ["-G", "--", address]
        let output = try run("/usr/bin/ssh", arguments)
        var hostname: String?
        var port = 22
        for line in output.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: " ", maxSplits: 1)
            guard parts.count == 2 else { continue }
            switch parts[0] {
            case "hostname": hostname = String(parts[1])
            case "port": port = Int(parts[1]) ?? 22
            default: break
            }
        }
        guard let hostname, !hostname.isEmpty else { throw TrustError.unresolved(address) }
        return (hostname, port)
    }

    private static func parse(_ line: Substring) -> Key? {
        guard !line.hasPrefix("#") else { return nil }
        let fields = line.split(separator: " ")
        guard fields.count >= 3, let blob = Data(base64Encoded: String(fields[2])) else { return nil }
        let fingerprint = "SHA256:" + fingerprintBase64(Data(SHA256.hash(data: blob)))
        return Key(host: String(fields[0]), type: String(fields[1]),
                   fingerprint: fingerprint, line: String(line))
    }

    private static func fingerprintBase64(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "=", with: "")
    }

    private static func run(_ executable: String, _ arguments: [String]) throws -> String {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }
}
