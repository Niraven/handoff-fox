import Foundation

@main
struct PreferenceMigrationChecks {
    static func main() throws {
        let suffix = UUID().uuidString
        let legacy = "local.handofffox.legacy.\(suffix)"
        let current = "local.handofffox.current.\(suffix)"
        let previous = UserDefaults(suiteName: legacy)!
        let defaults = UserDefaults(suiteName: current)!
        defer {
            previous.removePersistentDomain(forName: legacy)
            defaults.removePersistentDomain(forName: current)
        }

        func expect(_ condition: Bool, _ message: String) {
            if !condition {
                print("FAILED: \(message)")
                exit(1)
            }
        }

        previous.set(["citadel.local"], forKey: "linuxPeers")
        previous.set("citadel.local", forKey: "selectedLinuxPeer")
        previous.set(true, forKey: "automaticClipboard")
        previous.set("not ours", forKey: "somethingElse")

        PreferenceMigration.run(defaults: defaults, legacy: legacy)
        expect(defaults.stringArray(forKey: "linuxPeers") == ["citadel.local"],
               "a saved device list did not move")
        expect(defaults.string(forKey: "selectedLinuxPeer") == "citadel.local",
               "the selected device did not move")
        expect(defaults.bool(forKey: "automaticClipboard"), "an enabled setting did not move")
        expect(defaults.object(forKey: "somethingElse") == nil, "an unknown key was carried over")

        defaults.set(false, forKey: "automaticClipboard")
        PreferenceMigration.run(defaults: defaults, legacy: legacy)
        expect(defaults.bool(forKey: "automaticClipboard") == false,
               "a second run overwrote a setting the person changed")

        defaults.removePersistentDomain(forName: current)
        PreferenceMigration.run(defaults: defaults, legacy: "local.handofffox.absent.\(suffix)")
        expect(defaults.object(forKey: "linuxPeers") == nil, "an absent legacy domain created keys")

        print("Preference migration checks passed.")
    }
}
