import AppKit
import Combine
import Foundation

struct HandoffTransfer: Identifiable, Codable, Sendable {
    enum Direction: String, Codable, Sendable {
        case incoming, outgoing
    }

    enum Status: String, Codable, Sendable {
        case queued, sending, delivered, retry

        var label: String {
            switch self {
            case .queued: "Queued"
            case .sending: "Transferring…"
            case .delivered: "Delivered"
            case .retry: "Needs retry"
            }
        }
    }

    let address: String
    let direction: Direction
    var item: HandoffItem
    var created = Date()
    var status: Status = .queued
    var volume: String?
    var path: String?
    var error: String?
    var acknowledged = false

    var id: String { Self.key(direction, address: address, ticket: item.id) }

    static func key(_ direction: Direction, address: String, ticket: String) -> String {
        "\(direction.rawValue):\(address):\(ticket)"
    }

    var title: String {
        switch item.kind {
        case "file": item.name ?? "File"
        case "link": "Browser link"
        case "projects": "Open Projects"
        case "desktop": "Open Desktop"
        default: "Handoff"
        }
    }

    var destination: String {
        if let path { return path }
        switch direction {
        case .incoming: return "This Mac"
        case .outgoing:
            guard let volume else { return "Linux desktop" }
            return volume == "workspace" ? "Linux workspace" : "Linux home"
        }
    }

    mutating func finish(path: String?) {
        status = .delivered
        self.path = path
        error = nil
        if item.kind == "link" {
            item = .init(id: item.id, kind: item.kind, name: nil, url: nil, size: nil, sha256: nil)
        }
    }
}

@MainActor
final class HandoffInbox: ObservableObject {
    @Published private(set) var records: [HandoffTransfer] = []
    @Published private(set) var lastReceived: String?
    @Published private(set) var problem: String?

    private let storage: URL
    private let defaults: UserDefaults
    private let sshConfig: URL?
    private var storageReadable = true
    private var loop: Task<Void, Never>?
    private var listeningTo: String?
    private var receivePermit: FileHandoff.ReceivePermit?
    private var openProjects: (() -> Void)?
    private var openDesktop: ((String) -> Void)?
    private var active = Set<String>()
    private var staging = 0

    init(storage: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Handoff Fox/Transfers", isDirectory: true),
         defaults: UserDefaults = .standard, sshConfig: URL? = nil) {
        self.storage = storage
        self.defaults = defaults
        self.sshConfig = sshConfig
        guard FileManager.default.fileExists(atPath: ledger.path) else { return }
        do {
            let saved = try JSONDecoder().decode([HandoffTransfer].self, from: Data(contentsOf: ledger))
            records = saved.map { record in
                var recovered = record
                if recovered.status == .sending {
                    recovered.status = .retry
                    recovered.error = "Handoff Fox restarted while this transfer was in progress."
                }
                return recovered
            }
        } catch {
            storageReadable = false
            problem = "Could not read the saved transfer inbox."
        }
    }

    func start(address: String?, openProjects: @escaping () -> Void, openDesktop: ((String) -> Void)? = nil) {
        loop?.cancel()
        loop = nil
        listeningTo = nil
        receivePermit?.cancel()
        receivePermit = nil
        guard let address, PeerClient.validAddress(address) else { return }
        listeningTo = address
        receivePermit = FileHandoff.ReceivePermit()
        self.openProjects = openProjects
        self.openDesktop = openDesktop

        loop = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    let response = try await self?.request(PeerRequest(action: "pending"), on: address)
                    guard !Task.isCancelled, let self else { return }
                    let items = response?.handoffs ?? []
                    var failed = false
                    for item in items {
                        if Task.isCancelled { return }
                        do { try await self.deliver(item, from: address) }
                        catch { failed = true }
                    }
                    if failed {
                        try await Task.sleep(for: .seconds(3))
                    } else if !items.isEmpty {
                        try await Task.sleep(for: .milliseconds(200))
                    }
                } catch {
                    if Task.isCancelled { return }
                    try? await Task.sleep(for: .seconds(3))
                }
            }
        }
    }

    func sendFile(_ file: URL, to address: String, volume: String) async throws -> String {
        guard PeerClient.validAddress(address), ["home", "workspace"].contains(volume) else {
            throw failure("Choose a saved Linux device and volume.")
        }
        let waiting = records.filter { $0.direction == .outgoing && $0.status != .delivered }.count
        guard waiting + staging < 12 else {
            throw failure("Finish some of the 12 waiting transfers before adding another file.")
        }
        staging += 1
        defer { staging -= 1 }
        try createStorage()
        let ticket = FileHandoff.newTicket()
        let target = payload(ticket)
        let digest = try await Task.detached(priority: .utility) {
            try FileHandoff.stage(file, to: target)
        }.value
        let item = HandoffItem(id: ticket, kind: "file", name: file.lastPathComponent,
                               url: nil, size: nil, sha256: digest)
        let record = HandoffTransfer(address: address, direction: .outgoing, item: item, volume: volume)
        do { try save(record) }
        catch {
            try? FileManager.default.removeItem(at: target)
            throw error
        }
        guard let path = try await send(record) else { throw failure("The file transfer did not return a destination.") }
        return path
    }

    func sendLink(_ text: String, to address: String) async throws {
        guard PeerClient.validAddress(address), FileHandoff.browserURL(text) != nil else {
            throw failure("Choose a saved Linux device and an HTTP or HTTPS link.")
        }
        let waiting = records.filter { $0.direction == .outgoing && $0.status != .delivered }.count
        guard waiting + staging < 12 else {
            throw failure("Finish some of the 12 waiting transfers before adding another link.")
        }
        let item = HandoffItem(id: FileHandoff.newTicket(), kind: "link", name: nil,
                               url: text, size: nil, sha256: nil)
        let record = HandoffTransfer(address: address, direction: .outgoing, item: item)
        try save(record)
        _ = try await send(record)
    }

    func retry(_ record: HandoffTransfer) async {
        guard let latest = records.first(where: { $0.id == record.id }),
              latest.status == .queued || latest.status == .retry else { return }
        problem = nil
        do {
            if latest.direction == .outgoing {
                _ = try await send(latest)
            } else if listeningTo == latest.address {
                try await deliver(latest.item, from: latest.address)
            } else {
                problem = "Enable receiving from this device before retrying."
            }
        } catch {
            problem = error.localizedDescription
        }
    }

    func discard(_ record: HandoffTransfer) {
        guard let latest = records.first(where: { $0.id == record.id }),
              latest.direction == .outgoing, latest.status == .queued || latest.status == .retry,
              !active.contains(latest.id), FileHandoff.validTicket(latest.item.id) else { return }
        problem = nil
        do {
            try replaceRecords(records.filter { $0.id != latest.id })
            if latest.item.kind == "file" {
                let staged = payload(latest.item.id)
                if FileManager.default.fileExists(atPath: staged.path) {
                    try FileManager.default.removeItem(at: staged)
                }
            }
        } catch {
            problem = error.localizedDescription
        }
    }

    func reveal(_ record: HandoffTransfer) async {
        guard record.status == .delivered, record.item.kind == "file", let path = record.path else { return }
        problem = nil
        if record.direction == .incoming {
            guard FileManager.default.fileExists(atPath: path) else {
                problem = "This received file has been moved or removed."
                return
            }
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
        } else {
            do { _ = try await request(PeerRequest(action: "reveal-upload", project: record.item.id), on: record.address) }
            catch { problem = error.localizedDescription }
        }
    }

    func preferredVolume(for address: String) -> String {
        let volume = defaults.dictionary(forKey: "transferVolumes")?[address] as? String
        return volume == "workspace" ? "workspace" : "home"
    }

    func setPreferredVolume(_ volume: String, for address: String) {
        guard ["home", "workspace"].contains(volume) else { return }
        setPreference(volume, key: "transferVolumes", address: address)
    }

    func preferredFolder(for address: String) -> URL {
        if let path = defaults.dictionary(forKey: "transferFolders")?[address] as? String, path.hasPrefix("/") {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        return defaultReceiveFolder
    }

    func setPreferredFolder(_ folder: URL, for address: String) {
        guard folder.isFileURL, folder.path.hasPrefix("/") else { return }
        setPreference(folder.standardizedFileURL.path, key: "transferFolders", address: address)
    }

    private var defaultReceiveFolder: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Downloads/Handoff Fox", isDirectory: true)
    }

    private var ledger: URL { storage.appendingPathComponent("inbox.json") }

    private func payload(_ ticket: String) -> URL { storage.appendingPathComponent("\(ticket).payload") }

    private func setPreference(_ value: String, key: String, address: String) {
        guard PeerClient.validAddress(address) else { return }
        var devices = defaults.dictionary(forKey: key) ?? [:]
        devices[address] = value
        defaults.set(devices, forKey: key)
        objectWillChange.send()
    }

    private func createStorage() throws {
        guard storageReadable else { throw failure("Could not read the saved transfer inbox.") }
        try FileManager.default.createDirectory(at: storage, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
    }

    private func save(_ record: HandoffTransfer) throws {
        var updated = records.filter { $0.id != record.id }
        updated.append(record)
        updated.sort { $0.created > $1.created }
        var finished = 0
        updated = updated.filter {
            guard $0.status == .delivered, $0.direction == .outgoing || $0.acknowledged else { return true }
            finished += 1
            return finished <= 100
        }
        try replaceRecords(updated)
    }

    private func replaceRecords(_ updated: [HandoffTransfer]) throws {
        try createStorage()
        try JSONEncoder().encode(updated).write(to: ledger, options: .atomic)
        records = updated
    }

    private func send(_ record: HandoffTransfer) async throws -> String? {
        guard active.insert(record.id).inserted else { return nil }
        defer { active.remove(record.id) }
        var current = record
        current.status = .sending
        current.error = nil
        try save(current)
        do {
            let path: String?
            if record.item.kind == "file", let name = record.item.name,
               let digest = record.item.sha256, let volume = record.volume {
                let source = payload(record.item.id)
                let config = sshConfig
                path = try await Task.detached(priority: .utility) {
                    try FileHandoff.sendTicket(source, named: name, on: record.address,
                                               volume: volume, ticket: record.item.id,
                                               sha256: digest, sshConfig: config)
                }.value
            } else if record.item.kind == "link", let url = record.item.url {
                _ = try await request(PeerRequest(action: "deliver-link", project: record.item.id, url: url),
                                      on: record.address)
                path = nil
            } else {
                throw failure("The saved transfer is incomplete.")
            }
            current.finish(path: path)
            try save(current)
            if record.item.kind == "file" { try? FileManager.default.removeItem(at: payload(record.item.id)) }
            return path
        } catch {
            try? saveFailure(record, error)
            throw error
        }
    }

    private func deliver(_ item: HandoffItem, from address: String) async throws {
        guard listeningTo == address, let permit = receivePermit, FileHandoff.validTicket(item.id) else { return }
        let id = HandoffTransfer.key(.incoming, address: address, ticket: item.id)
        guard active.insert(id).inserted else { return }
        defer { active.remove(id) }

        var current: HandoffTransfer
        if let saved = records.first(where: { $0.id == id }) {
            current = saved
        } else {
            current = HandoffTransfer(address: address, direction: .incoming, item: item)
            if item.kind == "file" {
                let reserved = Set(records.filter { $0.direction == .incoming && $0.status != .delivered }
                    .compactMap(\.path))
                current.path = try FileHandoff.destination(for: item, in: preferredFolder(for: address),
                                                            reserved: reserved).path
            }
            try save(current)
        }

        if current.status != .delivered {
            let incoming = current
            current.status = .sending
            current.error = nil
            try save(current)
            do {
                if incoming.item.kind == "file", let path = incoming.path {
                    let target = URL(fileURLWithPath: path)
                    let folder = target.deletingLastPathComponent()
                    let config = sshConfig
                    let saved = try await Task.detached(priority: .utility) {
                        try FileHandoff.receive(incoming.item, from: address, into: folder,
                                                sshConfig: config, destination: target, permit: permit)
                    }.value
                    guard receivePermit === permit else { throw failure("Receiving from this device was paused.") }
                    current.finish(path: saved.path)
                    try save(current)
                    lastReceived = "Received \(saved.lastPathComponent)."
                } else {
                    try deliverAction(incoming)
                }
            } catch {
                try? saveFailure(incoming, error)
                throw error
            }
        }

        guard receivePermit === permit else { return }
        _ = try await request(PeerRequest(action: "ack", project: item.id), on: address)
        if var delivered = records.first(where: { $0.id == id }), !delivered.acknowledged {
            delivered.acknowledged = true
            try save(delivered)
        }
    }

    private func deliverAction(_ record: HandoffTransfer) throws {
        guard listeningTo == record.address else { throw failure("This device is no longer the receive target.") }
        let url = record.item.url.flatMap(FileHandoff.browserURL)
        switch record.item.kind {
        case "projects": break
        case "desktop":
            guard openDesktop != nil else { throw failure("Open Desktop is unavailable on this Mac.") }
        case "link":
            guard url != nil else { throw failure("The queued link is not a valid browser URL.") }
        default:
            throw failure("Update Handoff Fox to receive this kind of transfer.")
        }
        var delivered = record
        delivered.finish(path: nil)
        try save(delivered)
        // Record interactive actions first so a lost acknowledgement does not reopen a window.
        switch record.item.kind {
        case "projects":
            openProjects?()
            lastReceived = "Opened Projects from Linux."
        case "desktop":
            openDesktop?(record.address)
            lastReceived = "Opened Desktop from Linux."
        case "link":
            if let url, NSWorkspace.shared.open(url) {
                lastReceived = "Opened a link from Linux."
            } else {
                try save(record)
                throw failure("Could not open the queued link on this Mac.")
            }
        default: break
        }
    }

    private func saveFailure(_ record: HandoffTransfer, _ error: Error) throws {
        var failed = record
        failed.status = .retry
        failed.error = error.localizedDescription
        try save(failed)
    }

    private func request(_ request: PeerRequest, on address: String) async throws -> PeerReply {
        let config = sshConfig
        return try await Task.detached(priority: .utility) {
            try PeerClient.request(request, on: address, sshConfig: config)
        }.value
    }

    private func failure(_ reason: String) -> PeerClient.Failure { .init(reason: reason) }
}
