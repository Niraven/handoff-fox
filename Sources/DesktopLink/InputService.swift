import Darwin
import Foundation

struct InputStatus: Equatable, Sendable {
    let serverRunning: Bool
    let tunnelRunning: Bool
    let connected: Bool

    var title: String {
        if connected { return "Connected" }
        if !serverRunning { return "Input paused" }
        if !tunnelRunning { return "Tunnel offline" }
        return "Waiting for Linux"
    }

    func justConnected(after previous: Self?) -> Bool {
        previous?.connected == false && connected
    }
}

struct CitadelActivity: Decodable, Equatable, Sendable {
    let reviews: Int?
    let workspaceFreeGiB: Int?

    var needsAttention: Bool { !attentionSummary.isEmpty }

    var attentionSummary: String {
        var reasons: [String] = []
        if let reviews, reviews > 0 { reasons.append("\(reviews) in review") }
        if let workspaceFreeGiB, workspaceFreeGiB < 15 { reasons.append("Workspace low") }
        return reasons.joined(separator: " · ")
    }
}

enum Shortcut: String, Sendable {
    case hermes, herdr, workspace
}

enum InputService {
    static let domain = "gui/\(getuid())"
    static let server = "local.citadel.deskflow"
    static let tunnel = "local.citadel.input-tunnel"

    static func runningPID(in description: String) -> String? {
        var state: String?
        var pid: String?
        for line in description.split(separator: "\n") {
            let text = line.trimmingCharacters(in: .whitespaces)
            if state == nil, text.hasPrefix("state = ") {
                state = String(text.dropFirst(8))
            }
            if pid == nil, text.hasPrefix("pid = "),
               let value = Int(text.dropFirst(6)), value > 0 {
                pid = String(value)
            }
        }
        return state == "running" ? pid : nil
    }

    static func status() -> InputStatus {
        let serverPID = pid(of: server)
        let tunnelPID = pid(of: tunnel)
        let established: Bool
        if let serverPID, tunnelPID != nil {
            let result = run("/usr/sbin/lsof", ["-b", "-nP", "-a", "-p", serverPID,
                                                "-iTCP:24800", "-sTCP:ESTABLISHED", "-Fn"])
            established = result.code == 0 && result.output.contains("127.0.0.1:24800->127.0.0.1:")
        } else {
            established = false
        }
        return InputStatus(serverRunning: serverPID != nil,
                           tunnelRunning: tunnelPID != nil, connected: established)
    }

    static func activity(on address: String) -> CitadelActivity? {
        let result = remote(".local/bin/desktop-link --activity", on: address)
        guard result.code == 0 else { return nil }
        return try? JSONDecoder().decode(CitadelActivity.self, from: Data(result.output.utf8))
    }

    static func open(_ target: Shortcut, on address: String) -> String? {
        let result = remote(".local/bin/desktop-link --open " + target.rawValue, on: address)
        return result.code == 0 ? nil : "Could not open \(target.rawValue) on Linux."
    }

    private static func remote(_ command: String, on address: String) -> (code: Int32, output: String) {
        guard let arguments = try? PeerClient.sshArguments(address: address, command: command) else { return (1, "") }
        return run("/usr/bin/ssh", arguments)
    }

    static func pause() -> String? {
        let result = run("/bin/launchctl", ["bootout", "\(domain)/\(server)"])
        return result.code == 0 || pid(of: server) == nil
            ? nil : "macOS could not pause Deskflow."
    }

    static func resume() -> String? {
        for label in [tunnel, server] {
            if pid(of: label) != nil { continue }
            let target = "\(domain)/\(label)"
            if run("/bin/launchctl", ["print", target]).code == 0 {
                if run("/bin/launchctl", ["kickstart", target]).code != 0 {
                    return "macOS could not start \(label)."
                }
            } else {
                let plist = FileManager.default.homeDirectoryForCurrentUser
                    .appendingPathComponent("Library/LaunchAgents/\(label).plist")
                guard FileManager.default.fileExists(atPath: plist.path) else {
                    return "The saved pairing is missing its launch definition."
                }
                if run("/bin/launchctl", ["bootstrap", domain, plist.path]).code != 0 {
                    return "macOS could not load \(label)."
                }
            }
        }
        return nil
    }

    private static func pid(of label: String) -> String? {
        let result = run("/bin/launchctl", ["print", "\(domain)/\(label)"])
        return result.code == 0 ? runningPID(in: result.output) : nil
    }

    private static func run(_ executable: String, _ arguments: [String]) -> (code: Int32, output: String) {
        let command = Process()
        let pipe = Pipe()
        command.executableURL = URL(fileURLWithPath: executable)
        command.arguments = arguments
        command.standardOutput = pipe
        command.standardError = FileHandle.nullDevice
        command.standardInput = FileHandle.nullDevice
        do { try command.run() } catch { return (1, "") }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        command.waitUntilExit()
        return (command.terminationStatus, String(decoding: data, as: UTF8.self))
    }
}
