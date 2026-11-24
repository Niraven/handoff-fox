import CryptoKit
import Darwin
import Foundation

struct LinuxProject: Codable, Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let canBuild: Bool
}

struct LinuxPeer: Codable, Identifiable, Equatable, Sendable {
    var id: String { address }
    let address: String
    let name: String
}

struct PeerRequest: Encodable, Sendable {
    let version = 1
    let action: String
    var project: String?
    var name: String?
    var path: String?
    var url: String?
    var text: String?
}

struct PeerReply: Decodable, Sendable {
    let version: Int
    let ok: Bool
    let name: String?
    let system: String?
    let projects: [LinuxProject]?
    let title: String?
    let output: String?
    let exitCode: Int?
    let elapsedMs: Int?
    let truncated: Bool?
    let error: String?
    let artifact: BuildArtifact?
    let artifactError: String?
    let text: String?
    let volumes: [LinuxVolume]?
    let handoffs: [HandoffItem]?
    let path: String?
    let sha256: String?
    let desktopOutput: String?
    let desktopStatus: String?

    var desktopAvailability: DesktopAvailability? { desktopStatus.flatMap(DesktopAvailability.init(rawValue:)) }
}

enum DesktopAvailability: String, Sendable {
    case ready, needsGliff, needsHyprland
}

struct BuildArtifact: Decodable, Sendable {
    let name: String
    let data: Data
    let sha256: String

    var verified: Bool {
        data.count <= 2 * 1024 * 1024 &&
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() == sha256
    }
}

enum PeerClient {
    private static let receiverCommand = ".local/bin/desktop-link-peer"

    struct Failure: LocalizedError {
        enum Kind { case other, untrustedHost, changedHost, authentication, missingReceiver }
        let reason: String
        var kind: Kind = .other
        var errorDescription: String? { reason }
    }

    static func validAddress(_ address: String) -> Bool {
        !address.hasPrefix("-") && !address.hasSuffix("@") &&
            address.filter { $0 == "@" }.count <= 1 &&
            address.range(of: #"^[A-Za-z0-9_:\[][A-Za-z0-9_.:@\[\]%-]{0,252}$"#,
                          options: .regularExpression) != nil
    }

    static func sshArguments(address: String, config: URL? = nil, command: String) throws -> [String] {
        guard validAddress(address) else {
            throw Failure(reason: "Enter a saved SSH host alias or user@hostname.")
        }
        let options = config.map { ["-F", $0.path] } ?? []
        return options + ["-T", "-o", "BatchMode=yes", "-o", "StrictHostKeyChecking=yes",
                          "-o", "ConnectTimeout=5", "-o", "ServerAliveInterval=5",
                          "-o", "ServerAliveCountMax=2", "-o", "ForwardAgent=no",
                          "-o", "ForwardX11=no", "-o", "ClearAllForwardings=yes",
                          "--", address, command]
    }

    static func request(_ action: PeerRequest, on address: String, sshConfig: URL? = nil) throws -> PeerReply {
        let data = try JSONEncoder().encode(action)
        let limit = action.action == "clipboard-put" ? 420_000 : 16_384
        guard data.count <= limit else { throw Failure(reason: "This request is too large.") }

        let timeout: Double = action.action == "build" ? 110 : (["pair", "desktop"].contains(action.action) ? 12 : 32)
        let text = try exchange(data, on: address, sshConfig: sshConfig, command: receiverCommand, timeout: timeout)

        let line = text.split(whereSeparator: \.isNewline).last
        guard let line, let reply = try? JSONDecoder().decode(PeerReply.self, from: Data(line.utf8)),
              reply.version == action.version else {
            throw Failure(reason: "The Linux receiver returned an incompatible response.")
        }
        guard reply.ok else { throw Failure(reason: reply.error ?? "The Linux action failed.") }
        if let artifact = reply.artifact, !artifact.verified {
            throw Failure(reason: "The returned build file failed verification.")
        }
        return reply
    }

    static func pair(_ address: String, receiver: URL?, sshConfig: URL? = nil) throws -> PeerReply {
        let hello = PeerRequest(action: "pair")
        do {
            return try request(hello, on: address, sshConfig: sshConfig)
        } catch let error as Failure where error.kind == .missingReceiver {
            guard let receiver else { throw error }
            let script = try Data(contentsOf: receiver)
            guard !script.isEmpty, script.count <= 131_072 else {
                throw Failure(reason: "Reinstall Handoff Fox to restore the Linux receiver.")
            }
            let digest = SHA256.hash(data: script).map { String(format: "%02x", $0) }.joined()
            _ = try exchange(script, on: address, sshConfig: sshConfig,
                             command: "python3 -c '\(installReceiver)' \(digest)", timeout: 12)
            return try request(hello, on: address, sshConfig: sshConfig)
        }
    }

    private static let installReceiver = """
    import hashlib, os, pathlib, sys, tempfile
    if sys.version_info < (3, 9):
        sys.exit(83)
    data = sys.stdin.buffer.read(131073)
    if len(data) > 131072 or hashlib.sha256(data).hexdigest() != sys.argv[1]:
        sys.exit(85)
    destination = pathlib.Path.home() / ".local/bin/desktop-link-peer"
    destination.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile(dir=destination.parent) as staged:
        staged.write(data)
        staged.flush()
        os.fchmod(staged.fileno(), 0o755)
        try:
            os.link(staged.name, destination)
        except FileExistsError:
            pass
    """

    private static func exchange(_ data: Data, on address: String, sshConfig: URL?,
                                 command: String, timeout: Double) throws -> String {
        let ssh = Process()
        let input = Pipe()
        let output = Pipe()
        ssh.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        ssh.arguments = try sshArguments(address: address, config: sshConfig, command: command)
        _ = fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
        ssh.standardInput = input
        ssh.standardOutput = output
        ssh.standardError = output
        do { try ssh.run() } catch { throw Failure(reason: "Could not start OpenSSH on this Mac.") }

        let timer = DispatchSource.makeTimerSource()
        timer.schedule(deadline: .now() + timeout)
        timer.setEventHandler { if ssh.isRunning { ssh.terminate() } }
        timer.resume()
        defer { timer.cancel() }

        do {
            try input.fileHandleForWriting.write(contentsOf: data)
            try input.fileHandleForWriting.close()
        } catch {
            try? input.fileHandleForWriting.close()
        }

        var received = Data()
        while let chunk = try output.fileHandleForReading.read(upToCount: 16_384), !chunk.isEmpty {
            received.append(chunk)
            if received.count > 3_500_000 {
                ssh.terminate()
                ssh.waitUntilExit()
                throw Failure(reason: "The Linux receiver returned too much data.")
            }
        }
        ssh.waitUntilExit()
        let text = String(decoding: received, as: UTF8.self)
        if ssh.terminationStatus == 0 { return text }
        if text.contains("HOST IDENTIFICATION HAS CHANGED") {
            throw Failure(reason: "The SSH host key changed. Verify the new fingerprint on Linux before reconnecting.", kind: .changedHost)
        }
        if text.contains("Host key verification failed") {
            throw Failure(reason: "Verify the Linux host fingerprint in Terminal, then pair again.", kind: .untrustedHost)
        }
        if ssh.terminationStatus == 126, command == receiverCommand {
            throw Failure(reason: "The Linux receiver exists but couldn’t run. Check its permissions on Linux.")
        }
        if text.contains("Permission denied") {
            throw Failure(reason: "This Linux account needs an SSH key. Check key sign-in in Terminal, then try again.", kind: .authentication)
        }
        switch ssh.terminationStatus {
        case 127 where command == receiverCommand && text.contains(receiverCommand):
            throw Failure(reason: "The Handoff Fox receiver is missing on Linux.", kind: .missingReceiver)
        case 83, 127: throw Failure(reason: "Install Python 3.9 or later on Linux, then try again.")
        case 85: throw Failure(reason: "The Linux receiver transfer failed verification. Try pairing again.")
        default: throw Failure(reason: "SSH couldn’t reach the device. Check that it’s awake and connected to your network, then retry.")
        }
    }
}
