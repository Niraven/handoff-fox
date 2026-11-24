import AppKit
import Combine
import Darwin
import Foundation
import OSLog

private struct ClipboardFrame: Codable, Sendable {
    let kind: String
    var text: String?
}

@MainActor
final class ClipboardSync: ObservableObject {
    @Published private(set) var enabled: Bool
    @Published private(set) var ready = false

    let address: String?
    private let board: NSPasteboard
    private let sshConfig: URL?
    private let writes = DispatchQueue(label: "local.desktoplink.clipboard")
    private let log = Logger(subsystem: "local.desktoplink.control", category: "Clipboard")
    private var connected = false
    private var observed = 0
    private var loop: Task<Void, Never>?
    private var reader: Task<Void, Never>?
    private var process: Process?
    private var writer: FileHandle?
    private var channel: UUID?
    private var frames = Data()
    private var retryAfter = Date.distantPast
    private var heartbeat = Date.distantPast

    init(address: String?, enabled: Bool, board: NSPasteboard = .general, sshConfig: URL? = nil) {
        self.address = address
        self.enabled = enabled
        self.board = board
        self.sshConfig = sshConfig
    }

    func setEnabled(_ value: Bool) {
        enabled = value
        reconcile()
    }

    func setConnected(_ value: Bool) {
        connected = value
        reconcile()
    }

    private func reconcile() {
        guard enabled, connected, address != nil else {
            loop?.cancel()
            loop = nil
            close()
            return
        }
        if loop == nil {
            retryAfter = .distantPast
            loop = Task { [weak self] in
                while !Task.isCancelled {
                    self?.tick()
                    try? await Task.sleep(for: .milliseconds(140))
                }
            }
        }
    }

    private func tick() {
        let now = Date()
        if process == nil {
            if now >= retryAfter { start() }
            return
        }
        if now >= heartbeat {
            heartbeat = now.addingTimeInterval(8)
            send(ClipboardFrame(kind: "ping"))
        }
        if ready { _ = sendNewMacCopy() }
    }

    private func sendNewMacCopy() -> Bool {
        let count = board.changeCount
        guard count != observed else { return false }
        observed = count
        guard !ClipboardTransfer.isProtected(board),
              let text = board.string(forType: .string), ClipboardTransfer.valid(text),
              board.changeCount == count else { return false }

        send(ClipboardFrame(kind: "clipboard", text: text))
        return true
    }

    private func start() {
        guard let address, let arguments = try? PeerClient.sshArguments(
            address: address, config: sshConfig, command: ".local/bin/desktop-link-peer --watch-clipboard"
        ) else {
            retryAfter = Date().addingTimeInterval(4)
            return
        }
        let ssh = Process()
        let input = Pipe()
        let output = Pipe()
        let handle = input.fileHandleForWriting
        _ = fcntl(handle.fileDescriptor, F_SETNOSIGPIPE, 1)
        ssh.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        ssh.arguments = arguments
        ssh.standardInput = input
        ssh.standardOutput = output
        ssh.standardError = FileHandle.nullDevice
        observed = board.changeCount
        do { try ssh.run() } catch {
            retryAfter = Date().addingTimeInterval(4)
            return
        }

        let identity = UUID()
        channel = identity
        process = ssh
        writer = handle
        heartbeat = .distantPast
        let source = output.fileHandleForReading
        reader = Task.detached { [weak self] in
            defer { try? source.close() }
            var buffer = [UInt8](repeating: 0, count: 8192)
            while !Task.isCancelled {
                let count = buffer.withUnsafeMutableBytes {
                    Darwin.read(source.fileDescriptor, $0.baseAddress, $0.count)
                }
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { break }
                await self?.receive(Data(buffer.prefix(count)), on: identity)
            }
            await self?.ended(identity)
        }
    }

    private func send(_ frame: ClipboardFrame) {
        guard let writer, var bytes = try? JSONEncoder().encode(frame) else { return }
        bytes.append(10)
        let payload = bytes
        writes.async { try? writer.write(contentsOf: payload) }
    }

    private func receive(_ bytes: Data, on identity: UUID) {
        guard identity == channel else { return }
        frames.append(bytes)
        while let newline = frames.firstIndex(of: 10) {
            let line = frames[..<newline]
            frames.removeSubrange(...newline)
            guard line.count <= 420_000,
                  let frame = try? JSONDecoder().decode(ClipboardFrame.self, from: line) else {
                close()
                return
            }
            switch frame.kind {
            case "ready":
                ready = true
                log.info("Automatic clipboard sharing connected")
            case "clipboard":
                guard ready, let text = frame.text, ClipboardTransfer.valid(text),
                      !sendNewMacCopy() else { continue }
                board.clearContents()
                board.setString(text, forType: .string)
                observed = board.changeCount
            default:
                continue
            }
        }
        if frames.count > 420_000 { close() }
    }

    private func ended(_ identity: UUID) {
        if identity == channel { close() }
    }

    private func close() {
        channel = nil
        reader?.cancel()
        reader = nil
        if let process, process.isRunning { process.terminate() }
        process = nil
        if let writer { writes.async { try? writer.close() } }
        writer = nil
        frames.removeAll(keepingCapacity: false)
        ready = false
        retryAfter = Date().addingTimeInterval(4)
    }
}
