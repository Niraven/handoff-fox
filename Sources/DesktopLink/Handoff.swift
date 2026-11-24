import AppKit
import Combine
import CryptoKit
import Darwin
import Foundation
import OSLog

struct LinuxVolume: Decodable, Identifiable, Sendable {
    let id: String
    let name: String
    let path: String
    let free: Int64
    let total: Int64

    var capacity: String {
        let gibibyte: Int64 = 1_073_741_824
        return "\(free / gibibyte) of \(total / gibibyte) GiB free"
    }
}

struct HandoffItem: Decodable, Sendable {
    let id: String
    let kind: String
    let name: String?
    let url: String?
    let size: Int?
    let sha256: String?
}

enum FileHandoff {
    static let limit = 128 * 1024 * 1024

    private struct Header: Encodable {
        let id: String
        let name: String
        let size: Int
        let volume: String
    }

    static func browserURL(_ text: String) -> URL? {
        guard text.utf8.count <= 4096,
              !text.unicodeScalars.contains(where: { $0.value <= 32 || $0.value == 127 }),
              let url = URL(string: text), let scheme = url.scheme?.lowercased(),
              ["http", "https"].contains(scheme), url.host?.isEmpty == false,
              url.user == nil, url.password == nil else { return nil }
        return url
    }

    static func send(_ file: URL, on address: String, volume: String, sshConfig: URL? = nil) throws -> String {
        guard validName(file.lastPathComponent) else { throw failure("Choose a visible project file without credentials.") }
        let info = try file.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard info.isRegularFile == true, let size = info.fileSize, (0...limit).contains(size) else {
            throw failure("Choose a regular file up to 128 MiB.")
        }
        let fileHandle = try FileHandle(forReadingFrom: file)
        defer { try? fileHandle.close() }
        let input = Pipe()
        let writer = input.fileHandleForWriting
        _ = fcntl(writer.fileDescriptor, F_SETNOSIGPIPE, 1)
        let (ssh, output, timer) = try start(".local/bin/desktop-link-peer --upload", on: address,
                                            config: sshConfig, input: input)
        defer { timer.cancel() }

        let header = Header(id: UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased(),
                            name: file.lastPathComponent, size: size, volume: volume)
        var digest = SHA256()
        var streamed = 0
        let sent: Bool
        do {
            var metadata = try JSONEncoder().encode(header)
            metadata.append(10)
            try writer.write(contentsOf: metadata)
            while let data = try fileHandle.read(upToCount: 262_144), !data.isEmpty {
                streamed += data.count
                guard streamed <= size else { throw failure("The file changed during transfer.") }
                digest.update(data: data)
                try writer.write(contentsOf: data)
            }
            sent = true
        } catch { sent = false }
        try? writer.close()
        let data = output.readDataToEndOfFile()
        ssh.waitUntilExit()
        let receipt = try? JSONDecoder().decode(PeerReply.self, from: data)
        guard sent, receipt?.ok == true, ssh.terminationStatus == 0,
              receipt?.sha256 == hex(digest), let path = receipt?.path else {
            throw failure(receipt?.error ?? "File transfer stopped. Choose the file again to retry.")
        }
        return path
    }

    static func receive(_ item: HandoffItem, from address: String, into folder: URL,
                        sshConfig: URL? = nil) throws -> URL {
        guard item.id.range(of: #"^[0-9a-f]{32}$"#, options: .regularExpression) != nil,
              let name = item.name, validName(name), let size = item.size, (0...limit).contains(size),
              let expected = item.sha256 else { throw failure("Invalid queued file metadata.") }

        let fs = FileManager.default
        try fs.createDirectory(at: folder, withIntermediateDirectories: true,
                               attributes: [.posixPermissions: 0o700])
        let normal = folder.appendingPathComponent(name)
        let recovered = folder.appendingPathComponent("\(item.id)-\(name)")
        let target = fs.fileExists(atPath: normal.path) ? recovered : normal
        for candidate in [normal, recovered] where fs.fileExists(atPath: candidate.path) {
            if (try? checksum(candidate, size: size)) == expected { return candidate }
        }

        let partial = folder.appendingPathComponent(".\(item.id).part")
        if fs.fileExists(atPath: partial.path) { try fs.removeItem(at: partial) }
        guard fs.createFile(atPath: partial.path, contents: nil, attributes: [.posixPermissions: 0o600])
        else { throw failure("Could not create a local transfer file.") }
        defer { try? fs.removeItem(at: partial) }
        let file = try FileHandle(forWritingTo: partial)
        defer { try? file.close() }
        let (ssh, output, timer) = try start(".local/bin/desktop-link-peer --download \(item.id)", on: address,
                                            config: sshConfig)
        defer {
            timer.cancel()
            if ssh.isRunning { ssh.terminate() }
        }

        var count = 0
        var digest = SHA256()
        while let data = try output.read(upToCount: 262_144), !data.isEmpty {
            count += data.count
            guard count <= size else { throw failure("Linux returned more bytes than expected.") }
            digest.update(data: data)
            try file.write(contentsOf: data)
        }
        ssh.waitUntilExit()
        guard ssh.terminationStatus == 0, count == size, hex(digest) == expected
        else { throw failure("Transfer interrupted or checksum did not match.") }
        try file.close()
        try fs.moveItem(at: partial, to: target)
        return target
    }

    private static func checksum(_ file: URL, size: Int) throws -> String {
        guard try file.resourceValues(forKeys: [.fileSizeKey]).fileSize == size else { return "" }
        let source = try FileHandle(forReadingFrom: file)
        defer { try? source.close() }
        var digest = SHA256()
        while let data = try source.read(upToCount: 262_144), !data.isEmpty { digest.update(data: data) }
        return hex(digest)
    }

    private static func start(_ command: String, on address: String, config: URL?, input: Pipe? = nil)
        throws -> (Process, FileHandle, DispatchSourceTimer)
    {
        let ssh = Process()
        let output = Pipe()
        ssh.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        ssh.arguments = try PeerClient.sshArguments(address: address, config: config, command: command)
        ssh.standardInput = input.map { $0 as Any } ?? FileHandle.nullDevice
        ssh.standardOutput = output
        ssh.standardError = FileHandle.nullDevice
        try ssh.run()
        let timer = DispatchSource.makeTimerSource()
        timer.schedule(deadline: .now() + 120)
        timer.setEventHandler { if ssh.isRunning { ssh.terminate() } }
        timer.resume()
        return (ssh, output.fileHandleForReading, timer)
    }

    private static func validName(_ name: String) -> Bool {
        !name.isEmpty && name.utf8.count <= 220 && !name.hasPrefix(".") &&
        !name.contains("/") && !name.contains("\\") &&
        !name.unicodeScalars.contains { $0.value < 32 || $0.value == 127 } &&
        !["credentials", "cookies"].contains(name.lowercased()) &&
        !["pem", "key", "p12", "kdbx"].contains(URL(fileURLWithPath: name).pathExtension.lowercased())
    }

    private static func hex(_ digest: SHA256) -> String {
        digest.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func failure(_ message: String) -> PeerClient.Failure { .init(reason: message) }
}

@MainActor
final class HandoffInbox: ObservableObject {
    @Published private(set) var lastReceived: String?
    private let log = Logger(subsystem: "local.desktoplink.control", category: "Handoff")
    private var loop: Task<Void, Never>?
    private var openProjects: (() -> Void)?
    private var finished = Set<String>()
    private var receiving = Set<String>()

    func start(address: String?, openProjects: @escaping () -> Void) {
        guard let address, PeerClient.validAddress(address) else { return }
        self.openProjects = openProjects
        loop?.cancel()
        loop = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    let response = try await Task.detached(priority: .utility) {
                        try PeerClient.request(PeerRequest(action: "pending"), on: address)
                    }.value
                    guard !Task.isCancelled, let self else { return }
                    for item in response.handoffs ?? [] {
                        if Task.isCancelled { return }
                        try await self.deliver(item, from: address)
                    }
                    if !(response.handoffs ?? []).isEmpty { try await Task.sleep(for: .milliseconds(200)) }
                } catch {
                    if Task.isCancelled { return }
                    try? await Task.sleep(for: .seconds(3))
                }
            }
        }
    }

    private func deliver(_ item: HandoffItem, from address: String) async throws {
        guard receiving.insert(item.id).inserted else { return }
        defer { receiving.remove(item.id) }
        if !finished.contains(item.id) {
            switch item.kind {
            case "file":
                let folder = FileManager.default.homeDirectoryForCurrentUser
                    .appendingPathComponent("Downloads/Handoff Fox", isDirectory: true)
                let saved = try await Task.detached(priority: .utility) {
                    try FileHandoff.receive(item, from: address, into: folder)
                }.value
                lastReceived = "Received \(saved.lastPathComponent) in Downloads/Handoff Fox."
            case "link":
                guard let raw = item.url, let url = FileHandoff.browserURL(raw), NSWorkspace.shared.open(url)
                else { throw PeerClient.Failure(reason: "Could not open the queued link.") }
                lastReceived = "Opened a link from Linux."
                log.info("Handoff inbox opened a verified link")
            case "projects":
                openProjects?()
                lastReceived = "Opened your projects from Linux."
                log.info("Handoff inbox opened Projects")
            default:
                break
            }
            finished.insert(item.id)
        }
        _ = try await Task.detached(priority: .utility) {
            try PeerClient.request(PeerRequest(action: "ack", project: item.id), on: address)
        }.value
        finished.remove(item.id)
    }
}
