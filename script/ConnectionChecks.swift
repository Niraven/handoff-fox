import Foundation

@main
struct ConnectionChecks {
    @MainActor
    static func main() throws {
        let ready = try decode("""
            {"version":1,"ok":true,"system":"Linux","desktopStatus":"ready","clipboardAvailable":true}
            """)
        precondition(ConnectionCheck(receiver: ready).steps.map(\.state) == Array(repeating: .ready, count: 6))

        let old = try decode("""
            {"version":1,"ok":true,"system":"Linux","desktopStatus":"needsGliff"}
            """)
        precondition(ConnectionCheck(receiver: old).steps.map(\.state) ==
                     [.ready, .ready, .ready, .ready, .actionNeeded, .unchecked])

        let failures: [(PeerClient.Failure.Kind, Int, Bool)] = [
            (.unreachable, 0, false), (.untrustedHost, 1, true), (.changedHost, 1, false),
            (.authentication, 2, false), (.missingReceiver, 3, false), (.receiverError, 3, false)
        ]
        for (kind, phase, verificationAvailable) in failures {
            let check = ConnectionCheck(failure: .init(reason: "Fixture", kind: kind))
            precondition(check.steps.enumerated().allSatisfy { index, step in
                step.state == (index < phase ? .ready : index == phase ? .actionNeeded : .unchecked)
            })
            precondition(check.offersHostVerification == verificationAvailable)
        }

        let suite = "HandoffFox.ConnectionChecks.\(UUID())"
        guard let prefs = UserDefaults(suiteName: suite) else { fatalError("Could not open the test preferences") }
        defer { prefs.removePersistentDomain(forName: suite) }
        prefs.set("first-linux", forKey: "lastDesktopHost")
        prefs.set(["first-linux": DesktopMode.privateScreen.rawValue, "second-linux": "Unsupported mode"],
                  forKey: "desktopModesByPeer")
        prefs.set(["first-linux": true, "second-linux": false], forKey: "desktopActualSizeByPeer")
        let restored = RemoteDesktop(defaults: prefs)
        precondition(restored.lastHost == "first-linux")
        precondition(restored.preferredMode(for: "first-linux") == .privateScreen)
        precondition(restored.preferredMode(for: "second-linux") == .mirror)
        precondition(restored.prefersActualSize(for: "first-linux"))
        precondition(!restored.prefersActualSize(for: "second-linux"))
        precondition(!restored.prefersActualSize(for: "new-linux"))
        prefs.set("-invalid", forKey: "lastDesktopHost")
        precondition(RemoteDesktop(defaults: prefs).lastHost == nil)
        print("Connection phase reporting, saved desktop mode, and display scale checks passed.")
    }

    private static func decode(_ text: String) throws -> PeerReply {
        try JSONDecoder().decode(PeerReply.self, from: Data(text.utf8))
    }
}
