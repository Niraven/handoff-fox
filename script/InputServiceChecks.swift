@main
struct InputServiceChecks {
    static func main() {
        precondition(InputService.runningPID(in: "state = running\n\tpid = 42") == "42")
        precondition(InputService.runningPID(in: "state = not running\n\tpid = 42\nstate = running") == nil)
        precondition(InputService.runningPID(in: "state = running\n\tpid = 0") == nil)
        precondition(InputStatus(serverRunning: true, tunnelRunning: true, connected: false).title == "Waiting for Linux")
        precondition(InputStatus(serverRunning: true, tunnelRunning: false, connected: false).title == "Tunnel offline")
        let offline = InputStatus(serverRunning: true, tunnelRunning: true, connected: false)
        let online = InputStatus(serverRunning: true, tunnelRunning: true, connected: true)
        for previous in [nil, offline, online] {
            for next in [offline, online] {
                precondition(next.justConnected(after: previous) == (previous == offline && next == online))
            }
        }
        let healthy = CitadelActivity(scraperReady: true, hermesActive: true,
                                     herdrAgents: 0, reviews: 0, workspaceFreeGiB: 699)
        let attention = CitadelActivity(scraperReady: true, hermesActive: true,
                                       herdrAgents: 0, reviews: 2, workspaceFreeGiB: 14)
        precondition(!healthy.needsAttention)
        precondition(attention.attentionSummary == "2 in review · Workspace low")
        if CommandLine.arguments.contains("--live") {
            let status = InputService.status()
            print("Deskflow running: \(status.serverRunning), tunnel running: \(status.tunnelRunning), paired: \(status.connected)")
            precondition(status.connected)
        }
        print("Desktop Link status checks passed.")
    }
}
