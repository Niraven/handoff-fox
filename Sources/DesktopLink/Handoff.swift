import CryptoKit
import Darwin
import Foundation

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

struct HandoffItem: Codable, Sendable {
    let id: String
    let kind: String
    let name: String?
    let url: String?
    let size: Int?
    let sha256: String?
}

enum FileHandoff {
    static let limit = 128 * 1024 * 1024

    final class ReceivePermit: @unchecked Sendable {
        private let lock = NSLock()
        private var enabled = true

        func cancel() { lock.withLock { enabled = false } }

        func publish(_ change: () -> Int32) throws -> Int32 {
            try lock.withLock {
                guard enabled else { throw failure("Receiving from this device was paused.") }
                return change()
            }
        }
    }

    private struct Header: Encodable {
        let id: String
        let name: String
        let size: Int
        let volume: String
        let sha256: String?
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
        try upload(file, named: file.lastPathComponent, on: address, volume: volume,
                   ticket: newTicket(), expected: nil, sshConfig: sshConfig)
    }

    static func sendTicket(_ file: URL, named name: String, on address: String,
                           volume: String, ticket: String, sha256: String, sshConfig: URL? = nil) throws -> String {
        let request = PeerRequest(action: "upload-status", project: ticket, text: sha256)
        let previous: PeerReply
        do {
            previous = try PeerClient.request(request, on: address, sshConfig: sshConfig)
        } catch let error as PeerClient.Failure where error.reason == "Unknown Handoff Fox action." {
            throw failure("Update the Linux receiver to retry this transfer.")
        }
        if let path = previous.path, previous.sha256 == sha256 { return path }
        return try upload(file, named: name, on: address, volume: volume,
                          ticket: ticket, expected: sha256, sshConfig: sshConfig)
    }

    static func stage(_ file: URL, to target: URL) throws -> String {
        guard validName(file.lastPathComponent) else { throw failure("Choose a visible project file without credentials.") }
        let (source, size) = try openRegularFile(file)
        defer { try? source.close() }
        let targetHandle = try createPrivateFile(target)
        do {
            defer { try? targetHandle.close() }
            let result = try stream(source, expectedSize: size) { try targetHandle.write(contentsOf: $0) }
            try targetHandle.synchronize()
            return result
        } catch {
            try? FileManager.default.removeItem(at: target)
            throw error
        }
    }

    static func newTicket() -> String {
        UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    }

    private static func upload(_ file: URL, named name: String, on address: String, volume: String,
                               ticket: String, expected: String?, sshConfig: URL?) throws -> String {
        guard validName(name), validTicket(ticket) else { throw failure("Enter a valid transfer ticket and filename.") }
        let (fileHandle, size) = try openRegularFile(file)
        defer { try? fileHandle.close() }
        let input = Pipe()
        let writer = input.fileHandleForWriting
        _ = fcntl(writer.fileDescriptor, F_SETNOSIGPIPE, 1)
        let command = expected == nil ? "--upload" : "--upload-ticket"
        let (ssh, output, timer) = try start(".local/bin/desktop-link-peer \(command)", on: address,
                                            config: sshConfig, input: input)
        defer { timer.cancel() }

        let header = Header(id: ticket, name: name, size: size, volume: volume, sha256: expected)
        let sentDigest: String?
        do {
            var metadata = try JSONEncoder().encode(header)
            metadata.append(10)
            try writer.write(contentsOf: metadata)
            sentDigest = try stream(fileHandle, expectedSize: size) { try writer.write(contentsOf: $0) }
        } catch { sentDigest = nil }
        try? writer.close()
        let data = output.readDataToEndOfFile()
        ssh.waitUntilExit()
        let receipt = try? JSONDecoder().decode(PeerReply.self, from: data)
        guard let sentDigest, expected == nil || sentDigest == expected,
              receipt?.ok == true, ssh.terminationStatus == 0,
              receipt?.sha256 == sentDigest, let path = receipt?.path else {
            throw failure(receipt?.error ?? "The file transfer stopped before it was verified.")
        }
        return path
    }

    static func destination(for item: HandoffItem, in folder: URL, reserved: Set<String>) throws -> URL {
        let name = try verifiedMetadata(item).name
        let normal = folder.appendingPathComponent(name)
        if exists(normal) || reserved.contains(normal.path) {
            return folder.appendingPathComponent("\(item.id)-\(name)")
        }
        return normal
    }

    static func receive(_ item: HandoffItem, from address: String, into folder: URL,
                        sshConfig: URL? = nil, destination: URL? = nil,
                        permit: ReceivePermit = .init()) throws -> URL {
        let (name, size, expected) = try verifiedMetadata(item)

        let fs = FileManager.default
        try fs.createDirectory(at: folder, withIntermediateDirectories: true,
                               attributes: [.posixPermissions: 0o700])
        let normal = folder.appendingPathComponent(name)
        let recovered = folder.appendingPathComponent("\(item.id)-\(name)")
        if let destination, destination.path != normal.path && destination.path != recovered.path {
            throw failure("The saved destination does not match the transfer ticket.")
        }
        let target = destination ?? (exists(normal) ? recovered : normal)
        for candidate in destination.map({ [$0] }) ?? [normal, recovered] {
            if (try? checksum(candidate, size: size)) == expected { return candidate }
        }

        let partial = folder.appendingPathComponent(".handoff-\(newTicket()).part")
        let file = try createPrivateFile(partial)
        defer { try? fs.removeItem(at: partial) }
        defer { try? file.close() }
        let (ssh, output, timer) = try start(".local/bin/desktop-link-peer --download \(item.id)", on: address,
                                            config: sshConfig)
        defer {
            timer.cancel()
            if ssh.isRunning { ssh.terminate() }
        }

        let actual = try stream(output, expectedSize: size) { try file.write(contentsOf: $0) }
        ssh.waitUntilExit()
        guard ssh.terminationStatus == 0, actual == expected
        else { throw failure("Transfer interrupted or checksum did not match.") }
        try file.synchronize()
        try file.close()
        let published = try permit.publish { renamex_np(partial.path, target.path, UInt32(RENAME_EXCL)) }
        if published != 0, (try? checksum(target, size: size)) != expected {
            throw failure("Could not publish the file safely in the selected folder.")
        }
        return target
    }

    private static func exists(_ file: URL) -> Bool {
        var info = stat()
        return lstat(file.path, &info) == 0
    }

    private static func checksum(_ file: URL, size: Int) throws -> String {
        let (source, actual) = try openRegularFile(file)
        defer { try? source.close() }
        guard actual == size else { return "" }
        return try stream(source, expectedSize: size) { _ in }
    }

    private static func stream(_ source: FileHandle, expectedSize: Int, consume: (Data) throws -> Void) throws -> String {
        var count = 0
        var digest = SHA256()
        while let data = try source.read(upToCount: 262_144), !data.isEmpty {
            count += data.count
            guard count <= expectedSize else { throw failure("The transfer exceeded the expected file size.") }
            digest.update(data: data)
            try consume(data)
        }
        guard count == expectedSize else { throw failure("The transfer stopped before all bytes arrived.") }
        return hex(digest)
    }

    private static func openRegularFile(_ url: URL) throws -> (FileHandle, Int) {
        let descriptor = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { throw failure("The selected file could not be opened safely.") }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              (0...Int64(limit)).contains(info.st_size) else {
            _ = Darwin.close(descriptor)
            throw failure("Choose a regular file up to 128 MiB.")
        }
        return (FileHandle(fileDescriptor: descriptor, closeOnDealloc: true), Int(info.st_size))
    }

    private static func createPrivateFile(_ url: URL) throws -> FileHandle {
        let descriptor = Darwin.open(url.path, O_CREAT | O_EXCL | O_WRONLY | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw failure("Could not create a private transfer file.") }
        return FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    }

    private static func verifiedMetadata(_ item: HandoffItem) throws -> (name: String, size: Int, digest: String) {
        guard validTicket(item.id), let name = item.name, validName(name),
              let size = item.size, (0...limit).contains(size),
              let expected = item.sha256, expected.range(of: #"^[0-9a-f]{64}$"#, options: .regularExpression) != nil
        else { throw failure("Invalid queued file metadata.") }
        return (name, size, expected)
    }

    static func validTicket(_ value: String) -> Bool {
        value.range(of: #"^[0-9a-f]{32}$"#, options: .regularExpression) != nil
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
