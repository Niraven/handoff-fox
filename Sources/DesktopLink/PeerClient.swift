import CryptoKit
import Darwin
import Foundation

struct LinuxProject: Codable, Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let canBuild: Bool
    var presets: [LinuxJobPreset]? = nil
}

struct LinuxAgentSession: Decodable, Identifiable, Equatable, Sendable {
    let agent: String
    let session: String
    let pane: String

    var id: String { "\(agent):\(session):\(pane)" }
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
    var job: String?
    var preset: String?
    var argv: [String]?
    var artifact: String?
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
    /// Present when the receiver re-checked a file it had already delivered.
    let verified: Bool?
    let desktopOutput: String?
    let desktopStatus: String?
    let clipboardAvailable: Bool?
    let job: LinuxJob?
    let jobs: [LinuxJob]?
    let jobProtocol: Int?
    let transferProtocol: Int?
    let agents: [LinuxAgentSession]?
    let packageManager: String?
    let command: String?

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

    private static let controlDirectory: URL = {
        let base = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Handoff Fox/ssh", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        return base
    }()

    /// One authenticated session per device. Every request used to pay a full TCP
    /// handshake and key exchange; measured on loopback that was 212 ms of overhead
    /// per action against 8 ms over a reused connection.
    static func controlPath(for address: String, config: URL?) -> String {
        let digest = SHA256.hash(data: Data((address + "|" + (config?.path ?? "")).utf8))
            .map { String(format: "%02x", $0) }.joined()
        return controlDirectory.appendingPathComponent(String(digest.prefix(20))).path
    }

    struct Failure: LocalizedError {
        enum Kind { case other, unreachable, timeout, untrustedHost, changedHost, authentication, missingReceiver, receiverError }
        let reason: String
        var kind: Kind = .other
        var errorDescription: String? { reason }
    }

    final class TimeoutFlag: @unchecked Sendable {
        var fired = false
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
                          "-o", "ControlMaster=auto",
                          "-o", "ControlPath=\(controlPath(for: address, config: config))",
                          "-o", "ControlPersist=60",
                          "--", address, command]
    }

    static func request(_ action: PeerRequest, on address: String, sshConfig: URL? = nil) throws -> PeerReply {
        let data = try JSONEncoder().encode(action)
        let limit = action.action == "clipboard-put" ? 420_000 : 16_384
        guard data.count <= limit else { throw Failure(reason: "This request is too large.") }

        let timeout: Double = action.action == "build" ? 110 : (["pair", "desktop"].contains(action.action) ? 12 : 32)
        let text = try exchange(data, on: address, sshConfig: sshConfig, command: receiverCommand, timeout: timeout)

        let line = text.split(whereSeparator: \.isNewline).reversed().first { candidate in
            (try? JSONDecoder().decode(PeerReply.self, from: Data(candidate.utf8))) != nil
        }
        guard let line, let reply = try? JSONDecoder().decode(PeerReply.self, from: Data(line.utf8)) else {
            throw Failure(reason: "The Linux receiver returned an incompatible response.", kind: .receiverError)
        }
        guard reply.version == action.version else {
            throw Failure(reason: "The Linux receiver speaks protocol version \(reply.version). Update the Mac and Linux components together.",
                           kind: .receiverError)
        }
        guard reply.ok else { throw Failure(reason: reply.error ?? "The Linux action failed.", kind: .receiverError) }
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

    static func checkConnection(_ address: String) -> ConnectionCheck {
        do {
            let reply = try request(PeerRequest(action: "pair"), on: address)
            guard reply.system == "Linux" else {
                throw Failure(reason: "The receiver did not identify a Linux system.", kind: .receiverError)
            }
            return ConnectionCheck(receiver: reply)
        } catch let error as Failure {
            return ConnectionCheck(failure: error)
        } catch {
            return ConnectionCheck(failure: Failure(reason: error.localizedDescription))
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

        let timedOut = TimeoutFlag()
        let timer = DispatchSource.makeTimerSource()
        timer.schedule(deadline: .now() + timeout)
        timer.setEventHandler {
            if ssh.isRunning {
                timedOut.fired = true
                ssh.terminate()
            }
        }
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
        if timedOut.fired {
            throw Failure(reason: "Linux didn’t answer within \(Int(timeout)) seconds. Try again, and open Check connection if it keeps happening.",
                           kind: .timeout)
        }
        if text.contains("HOST IDENTIFICATION HAS CHANGED") {
            throw Failure(reason: "The SSH host key changed. Verify the new fingerprint on Linux before reconnecting.", kind: .changedHost)
        }
        if text.contains("Host key verification failed") {
            throw Failure(reason: "Verify the Linux host fingerprint in Terminal, then pair again.", kind: .untrustedHost)
        }
        if ssh.terminationStatus == 126, command == receiverCommand {
            throw Failure(reason: "The Linux receiver exists but couldn’t run. Check its permissions on Linux.", kind: .receiverError)
        }
        if ssh.terminationStatus == 255, text.contains("Permission denied") {
            throw Failure(reason: "This Linux account needs an SSH key. Check key sign-in in Terminal, then try again.", kind: .authentication)
        }
        switch ssh.terminationStatus {
        case 127 where command == receiverCommand && text.contains(receiverCommand):
            throw Failure(reason: "The Handoff Fox receiver is missing on Linux.", kind: .missingReceiver)
        case 83, 127: throw Failure(reason: "Install Python 3.9 or later on Linux, then try again.", kind: .receiverError)
        case 85: throw Failure(reason: "The Linux receiver transfer failed verification. Try pairing again.")
        default: throw Failure(reason: "SSH couldn’t reach the device. Check that it’s awake and connected to your network, then retry.",
                               kind: ssh.terminationStatus == 255 || ssh.terminationReason == .uncaughtSignal ? .unreachable : .receiverError)
        }
    }
}

struct ConnectionCheck: Sendable {
    enum State: Equatable, Sendable {
        case ready, actionNeeded, unchecked
    }

    struct Step: Identifiable, Sendable {
        let name: String
        let state: State
        let detail: String
        var id: String { name }
    }

    let steps: [Step]
    let offersHostVerification: Bool

    init(receiver: PeerReply) {
        let display: Step
        switch receiver.desktopAvailability {
        case .ready: display = Step(name: "Desktop session", state: .ready, detail: "Hyprland and Gliff ready")
        case .needsGliff: display = Step(name: "Desktop session", state: .actionNeeded, detail: "Install Gliff on Linux")
        case .needsHyprland: display = Step(name: "Desktop session", state: .actionNeeded, detail: "Sign in to Hyprland on Linux")
        case nil: display = Step(name: "Desktop session", state: .unchecked, detail: "Update the Linux receiver to check")
        }
        let clipboard: Step
        switch receiver.clipboardAvailable {
        case true?: clipboard = Step(name: "Clipboard tools", state: .ready, detail: "Linux desktop clipboard available")
        case false?: clipboard = Step(name: "Clipboard tools", state: .actionNeeded, detail: "Check the Linux desktop session and clipboard tools")
        case nil: clipboard = Step(name: "Clipboard tools", state: .unchecked, detail: "Update the Linux receiver to check")
        }
        steps = Self.readySteps + [display, clipboard]
        offersHostVerification = false
    }

    init(failure: PeerClient.Failure) {
        let phase: Int
        switch failure.kind {
        case .untrustedHost, .changedHost: phase = 1
        case .authentication: phase = 2
        case .receiverError, .missingReceiver, .timeout: phase = 3
        case .other, .unreachable: phase = 0
        }
        steps = Self.readySteps.enumerated().map { index, step in
            if index < phase { return step }
            if index == phase { return Step(name: step.name, state: .actionNeeded, detail: failure.reason) }
            return Step(name: step.name, state: .unchecked, detail: "Complete the earlier checks first")
        } + [Step(name: "Desktop session", state: .unchecked, detail: "Check the receiver first"),
             Step(name: "Clipboard tools", state: .unchecked, detail: "Check the receiver first")]
        offersHostVerification = failure.kind == .untrustedHost
    }

    private static let readySteps = [
        Step(name: "Network", state: .ready, detail: "SSH endpoint reached"),
        Step(name: "Host identity", state: .ready, detail: "SSH host key verified"),
        Step(name: "Key sign-in", state: .ready, detail: "Linux account authenticated"),
        Step(name: "Linux receiver", state: .ready, detail: "Receiver replied")
    ]
}
