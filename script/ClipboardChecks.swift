import AppKit
import Foundation

@main
struct ClipboardChecks {
    @MainActor
    static func main() async throws {
        let arguments = CommandLine.arguments
        guard arguments.count == 4 else {
            throw PeerClient.Failure(reason: "Provide a mode, SSH alias, and test SSH config.")
        }
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        let host = arguments[2]
        let config = URL(fileURLWithPath: arguments[3])
        switch arguments[1] {
        case "push":
            let marked = NSPasteboardItem()
            marked.setString("masked fixture", forType: .string)
            marked.setData(Data(), forType: .init("org.nspasteboard.ConcealedType"))
            board.writeObjects([marked])
            do {
                try await ClipboardTransfer.perform(.sendToLinux, host: host, board: board, sshConfig: config)
                throw PeerClient.Failure(reason: "The sender accepted a concealed item.")
            } catch let error as PeerClient.Failure {
                precondition(error.reason.contains("marked this clipboard item as sensitive"))
            }
            board.clearContents()
            board.setString("Mac → Linux 🦊\nSecond line\n", forType: .string)
            try await ClipboardTransfer.perform(.sendToLinux, host: host, board: board, sshConfig: config)
            print("Mac sent UTF-8 text. Concealed pasteboard content was refused.")
        case "pull":
            try await ClipboardTransfer.perform(.copyFromLinux, host: host, board: board, sshConfig: config)
            precondition(board.string(forType: .string) == "Linux → Mac λ\nFinal newline\n")
            print("Linux clipboard text reached the Mac, with Unicode and final newline intact.")
        default:
            throw PeerClient.Failure(reason: "Use push or pull.")
        }
    }
}
