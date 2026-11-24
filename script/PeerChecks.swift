import Foundation

@main
struct PeerChecks {
    static func main() throws {
        guard (2...3).contains(CommandLine.arguments.count) else {
            throw PeerClient.Failure(reason: "Provide the SSH host to test.")
        }
        let host = CommandLine.arguments[1]
        precondition(PeerClient.validAddress("citadel"))
        precondition(PeerClient.validAddress(host))
        precondition(!PeerClient.validAddress("-oProxyCommand"))
        precondition(!PeerClient.validAddress("person@host;another-command"))
        if CommandLine.arguments.count == 3 {
            let config = URL(fileURLWithPath: CommandLine.arguments[2])
            let hello = try PeerClient.request(PeerRequest(action: "pair"), on: host, sshConfig: config)
            precondition(hello.system == "Linux" && hello.projects?.isEmpty == true)
            let saved = try PeerClient.request(PeerRequest(action: "save", name: "Debian project",
                                                          path: "~/demo-project"),
                                               on: host, sshConfig: config)
            precondition(saved.projects?.first?.name == "Debian project")
            precondition(saved.projects?.first?.canBuild == false)
            let fresh = try PeerClient.request(PeerRequest(action: "pair"), on: host, sshConfig: config)
            precondition(fresh.projects == saved.projects)
            print("Fresh Linux user paired, saved a project, and received it on reconnect.")
            return
        }
        let info = try PeerClient.request(PeerRequest(action: "pair"), on: host)
        guard let build = info.projects?.first(where: { $0.name == "Waynergy Mac keymap" && $0.canBuild }),
              let folder = info.projects?.first(where: { $0.name == "Open Design" }) else {
            throw PeerClient.Failure(reason: "The expected saved projects were missing.")
        }

        let opening = try PeerClient.request(PeerRequest(action: "open", project: folder.id), on: host)
        precondition(opening.title == folder.name)
        print("Open on Linux: \(folder.name).")

        let page = try PeerClient.request(PeerRequest(action: "scrape", url: "https://example.com/"), on: host)
        precondition(page.exitCode == 0 && page.title == "Example Domain")
        precondition(page.output?.contains("documentation examples") == true)
        print("Scrape on Linux: \(page.title ?? ""), \(page.output?.utf8.count ?? 0) bytes, \(page.elapsedMs ?? 0) ms.")

        let receipt = try PeerClient.request(PeerRequest(action: "build", project: build.id), on: host)
        precondition(receipt.exitCode == 0)
        precondition(receipt.output?.contains("macos_keymap") == true)
        precondition(receipt.output?.contains("Fail:              0") == true || receipt.output?.contains("1/1") == true)
        guard let artifact = receipt.artifact else {
            throw PeerClient.Failure(reason: receipt.artifactError ?? "The Waynergy binary was missing.")
        }
        precondition(artifact.verified && artifact.name == "waynergy")
        print("Build on Linux: \(receipt.title ?? ""), \(receipt.elapsedMs ?? 0) ms.")
        print("Verified \(artifact.name), \(artifact.data.count) bytes.")
        if let lines = receipt.output?.split(separator: "\n") {
            for line in lines where line.contains("macos_keymap") || line.contains("Fail:") { print(line) }
        }
    }
}
