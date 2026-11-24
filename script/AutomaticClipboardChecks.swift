import AppKit
import Foundation

@main
struct AutomaticClipboardChecks {
    @MainActor
    static func main() async throws {
        let args = CommandLine.arguments
        guard args.count == 3 else {
            throw PeerClient.Failure(reason: "Provide the isolated Linux alias and SSH config.")
        }
        let host = args[1]
        let config = URL(fileURLWithPath: args[2])
        let board = NSPasteboard.withUniqueName()
        let sync = ClipboardSync(address: host, enabled: true, board: board, sshConfig: config)
        defer {
            sync.setConnected(false)
            board.releaseGlobally()
        }

        func linuxTextNow() throws -> String? {
            try PeerClient.request(PeerRequest(action: "clipboard-get"), on: host, sshConfig: config).text
        }

        func setMac(_ text: String) {
            board.clearContents()
            board.setString(text, forType: .string)
        }

        let linuxBaseline = "Existing Linux selection"
        let macBaseline = "Existing Mac selection"
        let macText = "Automatic Mac → Linux 🦊\nTrailing newline\n"
        let linuxText = "Automatic Linux → Mac λ\nTrailing newline\n"

        setMac(macBaseline)
        _ = try PeerClient.request(PeerRequest(action: "clipboard-put", text: linuxBaseline),
                                   on: host, sshConfig: config)
        sync.setConnected(true)
        try await wait("first connection") { sync.ready }
        precondition(board.string(forType: .string) == macBaseline)
        let linuxStart = try linuxTextNow()
        precondition(linuxStart == linuxBaseline)
        print("Automatic sharing connected and preserved both starting clipboards.")

        setMac(macText)
        try await wait("Mac to Wayland") {
            let copy = try? PeerClient.request(PeerRequest(action: "clipboard-get"), on: host, sshConfig: config)
            return copy?.text == macText
        }
        print("A Mac copy appeared on Wayland automatically, with Unicode and newlines.")

        _ = try PeerClient.request(PeerRequest(action: "clipboard-put", text: linuxText),
                                   on: host, sshConfig: config)
        try await wait("Wayland to Mac") { board.string(forType: .string) == linuxText }
        let changes = board.changeCount
        try await Task.sleep(for: .milliseconds(700))
        precondition(board.changeCount == changes)
        print("A Wayland copy appeared on the Mac automatically, without clipboard echo.")

        let marked = NSPasteboardItem()
        marked.setString("Concealed test fixture", forType: .string)
        marked.setData(Data(), forType: .init("org.nspasteboard.ConcealedType"))
        board.clearContents()
        board.writeObjects([marked])
        try await Task.sleep(for: .milliseconds(450))
        let beforePause = try linuxTextNow()
        precondition(beforePause == linuxText)
        print("The marked Mac item stayed local.")

        sync.setEnabled(false)
        setMac("While paused")
        try await Task.sleep(for: .milliseconds(350))
        precondition(!sync.ready)
        sync.setEnabled(true)
        try await wait("reconnection") { sync.ready }
        let afterPause = try linuxTextNow()
        precondition(afterPause == linuxText)
        precondition(board.string(forType: .string) == "While paused")
        setMac("Fresh copy after resume")
        try await wait("new copy after resume") {
            let copy = try? PeerClient.request(PeerRequest(action: "clipboard-get"), on: host, sshConfig: config)
            return copy?.text == "Fresh copy after resume"
        }
        print("Pause and resume preserved the starting selections and shared the next copy.")
    }

    @MainActor
    private static func wait(_ label: String, _ check: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if check() { return }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw PeerClient.Failure(reason: "Timed out during \(label).")
    }
}
