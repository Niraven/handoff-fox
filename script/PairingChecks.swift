import Foundation

@main
struct PairingChecks {
    static func main() throws {
        let args = CommandLine.arguments
        precondition(args.count == 5, "Pass a fresh Linux alias, SSH config, receiver file and expected mode.")
        let host = args[1]
        let config = URL(fileURLWithPath: args[2])
        let receiver = URL(fileURLWithPath: args[3])
        let mode = args[4]
        guard mode == "unknown-host" || mode == "first-pair" else {
            throw PeerClient.Failure(reason: "Expected unknown-host or first-pair.")
        }

        do {
            _ = try PeerClient.request(PeerRequest(action: "pair"), on: host, sshConfig: config)
            throw PeerClient.Failure(reason: "The fixture already has a receiver.")
        } catch let error as PeerClient.Failure {
            precondition(error.kind == (mode == "unknown-host" ? .untrustedHost : .missingReceiver))
        }
        if mode == "unknown-host" {
            print("First pairing rejected an unknown SSH host key.")
            return
        }

        let started = Date()
        let ready = try PeerClient.pair(host, receiver: receiver, sshConfig: config)
        precondition(ready.system == "Linux" && ready.jobProtocol == 1 && ready.transferProtocol == 1)
        precondition(ready.desktopAvailability == .needsGliff && ready.clipboardAvailable == false)
        let seconds = Date().timeIntervalSince(started)
        precondition(seconds < 120)
        let repeatPair = try PeerClient.pair(host, receiver: nil, sshConfig: config)
        precondition(repeatPair.system == "Linux" && repeatPair.projects == ready.projects)
        print(String(format: "Fresh headless receiver paired in %.2f s after SSH trust and key setup.", seconds))
    }
}
