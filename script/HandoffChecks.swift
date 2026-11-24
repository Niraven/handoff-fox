import Foundation

@main
struct HandoffChecks {
    static func main() throws {
        let args = CommandLine.arguments
        precondition(args.count == 5)
        let action = args[1], host = args[2]
        let config = URL(fileURLWithPath: args[3])
        let path = URL(fileURLWithPath: args[4])
        switch action {
        case "send":
            let info = try PeerClient.request(PeerRequest(action: "pair"), on: host, sshConfig: config)
            precondition(info.volumes?.contains { $0.id == "home" && $0.free > 0 } == true)
            precondition(info.volumes?.contains { $0.id == "workspace" && $0.free > 0 } == true)
            precondition(info.projects?.contains { $0.name == "Open Design" } == true)
            let saved = try FileHandoff.send(path, on: host, volume: "workspace", sshConfig: config)
            precondition(saved.hasPrefix("/workspace/Handoff Fox/Inbox/"))
            print("Mac-to-Citadel file landed on Workspace with a matching checksum.")
        case "receive":
            let pending = try PeerClient.request(PeerRequest(action: "pending"), on: host, sshConfig: config)
            guard let item = pending.handoffs?.first(where: { $0.name == "handoff-reconnect-sample.bin" }) else {
                throw PeerClient.Failure(reason: "Could not find the file queued during disconnection.")
            }
            let saved = try FileHandoff.receive(item, from: host, into: path, sshConfig: config)
            let repeated = try FileHandoff.receive(item, from: host, into: path, sshConfig: config)
            precondition(saved == repeated)
            let size = try saved.resourceValues(forKeys: [.fileSizeKey]).fileSize
            precondition(size == 4_194_304)
            _ = try PeerClient.request(PeerRequest(action: "ack", project: item.id), on: host, sshConfig: config)
            print("Queued file reached the Mac after reconnection. Checksum matched and retry created no duplicate.")
        case "link":
            precondition(FileHandoff.browserURL("https://example.com/") != nil)
            precondition(FileHandoff.browserURL("file:///etc/passwd") == nil)
            _ = try PeerClient.request(PeerRequest(action: "open-link", url: "https://example.com/"),
                                       on: host, sshConfig: config)
            print("Citadel accepted the HTTPS link using its graphical session.")
        default:
            throw PeerClient.Failure(reason: "Unknown check.")
        }
    }
}
