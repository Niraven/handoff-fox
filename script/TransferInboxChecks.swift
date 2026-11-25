import AppKit
import Combine
import CryptoKit
import Foundation

@main
struct TransferInboxChecks {
    @MainActor
    static func main() async throws {
        let fs = FileManager.default
        let root = fs.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fs.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fs.removeItem(at: root) }
        let suite = "local.handofffox.transfers.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let alpha = "alpha"
        let beta = "beta"

        let original = root.appendingPathComponent("note.txt")
        let contents = Data("Handoff Fox transfer fixture".utf8)
        let digest = SHA256.hash(data: contents).map { String(format: "%02x", $0) }.joined()
        try contents.write(to: original)
        let snapshot = root.appendingPathComponent("snapshot")
        let staged = try FileHandoff.stage(original, to: snapshot)
        precondition(staged == digest)
        try Data("Updated source".utf8).write(to: original, options: .atomic)
        let savedBytes = try Data(contentsOf: snapshot)
        precondition(savedBytes == contents)
        let alias = root.appendingPathComponent("alias.txt")
        try fs.createSymbolicLink(at: alias, withDestinationURL: original)
        do {
            _ = try FileHandoff.stage(alias, to: root.appendingPathComponent("copy"))
            preconditionFailure("Followed a symlink while staging.")
        } catch let error as PeerClient.Failure {
            precondition(error.reason == "The selected file could not be opened safely.")
        }

        let item = HandoffItem(id: FileHandoff.newTicket(), kind: "file", name: "note.txt",
                               url: nil, size: contents.count, sha256: digest)
        let destination = try FileHandoff.destination(for: item, in: root, reserved: [])
        precondition(destination != original)
        try fs.copyItem(at: snapshot, to: destination)
        let recovered = try FileHandoff.receive(item, from: "", into: root, destination: destination)
        precondition(recovered == destination)
        let other = HandoffItem(id: FileHandoff.newTicket(), kind: "file", name: "snapshot-2.txt",
                                url: nil, size: contents.count, sha256: digest)
        let reserved = Set([root.appendingPathComponent("snapshot-2.txt").path])
        let next = try FileHandoff.destination(for: other, in: root, reserved: reserved)
        precondition(next.lastPathComponent == "\(other.id)-snapshot-2.txt")

        let storage = root.appendingPathComponent("Transfers", isDirectory: true)
        try fs.createDirectory(at: storage, withIntermediateDirectories: true)
        let interrupted = HandoffTransfer(address: alpha, direction: .outgoing, item: item,
                                          status: .sending, volume: "workspace")
        var delivered = HandoffTransfer(address: alpha, direction: .incoming, item: item)
        delivered.finish(path: destination.path)
        try JSONEncoder().encode([interrupted, delivered]).write(to: storage.appendingPathComponent("inbox.json"))
        let inbox = HandoffInbox(storage: storage, defaults: defaults)
        precondition(inbox.records.first?.status == .retry)
        precondition(inbox.records.first?.item.id == item.id)
        precondition(inbox.records.last?.status == .delivered && inbox.records.last?.acknowledged == false)
        inbox.setPreferredVolume("workspace", for: alpha)
        inbox.setPreferredFolder(root, for: alpha)
        let restarted = HandoffInbox(storage: storage, defaults: defaults)
        precondition(restarted.preferredVolume(for: alpha) == "workspace")
        precondition(restarted.preferredVolume(for: beta) == "home")
        precondition(restarted.preferredFolder(for: alpha).path == root.path)
        precondition(restarted.preferredFolder(for: beta).path != root.path)

        let failedStorage = root.appendingPathComponent("Offline transfers", isDirectory: true)
        let offlineConfig = root.appendingPathComponent("ssh_config")
        try Data("Host *\n    ProxyCommand /usr/bin/false\n".utf8).write(to: offlineConfig)
        try fs.createDirectory(at: failedStorage, withIntermediateDirectories: true)
        let queuedRecords = (0..<11).map { _ in
            HandoffTransfer(address: alpha, direction: .outgoing,
                            item: .init(id: FileHandoff.newTicket(), kind: "link", name: nil,
                                        url: "https://example.com/", size: nil, sha256: nil),
                            status: .retry)
        }
        try JSONEncoder().encode(queuedRecords).write(to: failedStorage.appendingPathComponent("inbox.json"))
        let offline = HandoffInbox(storage: failedStorage, defaults: defaults, sshConfig: offlineConfig)
        var offlineSuccesses = 0
        let offlineObservation = offline.fileDeliveries.sink { _ in offlineSuccesses += 1 }
        defer { offlineObservation.cancel() }
        do {
            _ = try await offline.sendFile(original, to: alpha, volume: "home")
            preconditionFailure("An unavailable peer accepted the transfer.")
        } catch {
            precondition(offline.records.count == 12 && offline.records[0].status == .retry)
        }
        let queued = offline.records[0]
        precondition(offlineSuccesses == 0 && offline.latestOutgoingFile(to: alpha)?.id == queued.id)
        precondition(offline.latestOutgoingFile(to: beta) == nil)
        do {
            try await offline.sendLink("https://example.com/", to: alpha)
            preconditionFailure("The outbound queue exceeded 12 pending transfers.")
        } catch let failure as PeerClient.Failure {
            precondition(failure.reason.contains("12 waiting transfers"))
        }
        let afterRestart = HandoffInbox(storage: failedStorage, defaults: defaults, sshConfig: offlineConfig)
        precondition(afterRestart.records.first?.id == queued.id)
        await afterRestart.retry(queued)
        precondition(afterRestart.records.count == 12 && afterRestart.records[0].id == queued.id)
        precondition(afterRestart.records[0].status == .retry)
        let stagedPath = failedStorage.appendingPathComponent("\(queued.item.id).payload")
        let stagedBytes = try Data(contentsOf: stagedPath)
        precondition(stagedBytes == Data("Updated source".utf8))
        afterRestart.discard(queued)
        precondition(!fs.fileExists(atPath: stagedPath.path) && fs.fileExists(atPath: original.path))
        let afterDiscard = HandoffInbox(storage: failedStorage, defaults: defaults, sshConfig: offlineConfig)
        precondition(afterDiscard.records.count == 11 && !afterDiscard.records.contains { $0.id == queued.id })
        do {
            _ = try await afterDiscard.sendFile(original, to: alpha, volume: "home")
            preconditionFailure("An unavailable peer accepted the transfer.")
        } catch {
            precondition(afterDiscard.records.count == 12 && afterDiscard.records[0].id != queued.id)
        }

        let permit = FileHandoff.ReceivePermit()
        permit.cancel()
        do {
            _ = try permit.publish { preconditionFailure("A canceled listener published a file.") }
            preconditionFailure("The canceled listener reported success.")
        } catch let error as PeerClient.Failure {
            precondition(error.reason == "Receiving from this device was paused.")
        }

        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        let sync = ClipboardSync(address: alpha, enabled: true, board: board, defaults: defaults)
        precondition(sync.enabled && !sync.isEnabled(for: beta))
        sync.setTarget(beta, connected: false)
        precondition(sync.address == beta && !sync.enabled)
        sync.setEnabled(true, for: beta)
        precondition(sync.enabled && sync.isEnabled(for: alpha))
        sync.setTarget(alpha, connected: false)
        sync.setEnabled(false)
        let nextSync = ClipboardSync(address: alpha, enabled: true, board: board, defaults: defaults)
        precondition(!nextSync.enabled && nextSync.isEnabled(for: beta))
        nextSync.setTarget("--invalid", connected: true)
        precondition(nextSync.address == nil && !nextSync.enabled && !nextSync.ready)
        print("Transfer snapshots, same-ticket recovery, destinations, and per-device clipboard preferences passed.")
        let arguments = CommandLine.arguments
        if arguments.count == 4 {
            try await checkWire(address: arguments[1], config: URL(fileURLWithPath: arguments[2]),
                                fixture: URL(fileURLWithPath: arguments[3], isDirectory: true), defaults: defaults)
        }
    }

    @MainActor
    private static func checkWire(address: String, config: URL, fixture: URL, defaults: UserDefaults) async throws {
        let storage = fixture.appendingPathComponent("wire-storage", isDirectory: true)
        let receiveFolder = fixture.appendingPathComponent("receive", isDirectory: true)
        let destination = receiveFolder.appendingPathComponent("receive.txt")
        let fixtureFile = fixture.appendingPathComponent("receive.txt")
        let original = try Data(contentsOf: fixtureFile)
        let inbox = HandoffInbox(storage: storage, defaults: defaults, sshConfig: config)
        inbox.setPreferredFolder(receiveFolder, for: address)
        inbox.start(address: address, openProjects: {})
        defer { inbox.start(address: nil, openProjects: {}) }

        try await waitFor { inbox.records.contains { $0.direction == .incoming && $0.status == .delivered } }
        let received = try Data(contentsOf: destination)
        precondition(original == received)
        precondition(inbox.records.first?.acknowledged == false)
        try await waitFor { FileManager.default.fileExists(atPath: fixture.appendingPathComponent("ack-denied").path) }
        inbox.start(address: nil, openProjects: {})
        let edited = Data("Updated after arrival".utf8)
        try edited.write(to: destination)

        try Data().write(to: fixture.appendingPathComponent("allow-ack"))
        let restarted = HandoffInbox(storage: storage, defaults: defaults, sshConfig: config)
        var confirmations: [HandoffTransfer] = []
        let observation = restarted.fileDeliveries.sink { confirmations.append($0) }
        defer { observation.cancel() }
        restarted.start(address: address, openProjects: {})
        defer { restarted.start(address: nil, openProjects: {}) }
        try await waitFor { restarted.records.contains { $0.direction == .incoming && $0.acknowledged } }
        let preserved = try Data(contentsOf: destination)
        let entries = try FileManager.default.contentsOfDirectory(atPath: receiveFolder.path)
        precondition(preserved == edited && entries == ["receive.txt"])
        let sent = try await restarted.sendFile(fixtureFile, to: address, volume: "home")
        let returned = try Data(contentsOf: URL(fileURLWithPath: sent))
        precondition(returned == original)
        precondition(confirmations.count == 1 && confirmations[0].path == sent)
        await restarted.retry(confirmations[0])
        precondition(confirmations.count == 1)
        precondition(restarted.records.contains { $0.direction == .outgoing && $0.status == .delivered && $0.path == sent })
        print("Real SSH transfer passed both ways. An interrupted acknowledgement recovered without overwriting or duplicating the received file.")
    }

    @MainActor
    private static func waitFor(_ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw PeerClient.Failure(reason: "Timed out during the isolated SSH transfer fixture.")
    }
}
