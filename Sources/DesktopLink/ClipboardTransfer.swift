import AppKit
import Foundation

enum ClipboardDirection: Sendable {
    case sendToLinux, copyFromLinux
}

@MainActor
enum ClipboardTransfer {
    static func isProtected(_ board: NSPasteboard) -> Bool {
        (board.types ?? []).contains { type in
            let name = type.rawValue.lowercased()
            return name == "org.nspasteboard.concealedtype" ||
                   name == "org.nspasteboard.transienttype" ||
                   name.contains("passwordmanagerhint")
        }
    }

    static func valid(_ text: String) -> Bool {
        !text.isEmpty && !text.utf8.contains(0) && text.utf8.count <= 64 * 1024
    }

    static func perform(_ direction: ClipboardDirection, host: String,
                        board: NSPasteboard = .general, sshConfig: URL? = nil) async throws {
        switch direction {
        case .sendToLinux:
            guard !isProtected(board) else {
                throw PeerClient.Failure(reason: "The Mac marked this clipboard item as sensitive.")
            }
            guard let text = board.string(forType: .string), valid(text) else {
                throw PeerClient.Failure(reason: "Copy some plain text on your Mac first (up to 64 KiB).")
            }
            _ = try await Task.detached(priority: .userInitiated) {
                try PeerClient.request(PeerRequest(action: "clipboard-put", text: text),
                                       on: host, sshConfig: sshConfig)
            }.value

        case .copyFromLinux:
            let original = board.changeCount
            let reply = try await Task.detached(priority: .userInitiated) {
                try PeerClient.request(PeerRequest(action: "clipboard-get"), on: host, sshConfig: sshConfig)
            }.value
            guard let text = reply.text, valid(text) else {
                throw PeerClient.Failure(reason: "The Linux clipboard did not return supported text.")
            }
            guard board.changeCount == original else {
                throw PeerClient.Failure(reason: "Your Mac clipboard changed during transfer. Try Copy from Linux again.")
            }
            board.clearContents()
            guard board.setString(text, forType: .string) else {
                throw PeerClient.Failure(reason: "Could not write to the Mac clipboard.")
            }
        }
    }
}
