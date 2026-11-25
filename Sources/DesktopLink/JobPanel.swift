import AppKit
import SwiftUI

struct JobPanel: View {
    @ObservedObject var model: WorkbenchModel
    @State private var expanded = false

    private var pollingKey: [String] {
        guard expanded, let host = model.selected else { return [] }
        return [host] + model.jobs.filter { $0.state.isActive }.map(\.id).sorted()
    }

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 9) {
                if model.jobs.isEmpty {
                    Text("Run an approved preset from a saved project.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                ForEach(model.jobs.prefix(20)) { job in
                    row(job)
                }
                if let detail = model.jobDetail,
                   let displayed = detail.job,
                   let current = model.jobs.first(where: { $0.id == displayed.id }) {
                    jobResult(current, reply: detail)
                }
            }
            .padding(.top, 8)
            .task(id: pollingKey) {
                guard expanded else { return }
                while !Task.isCancelled {
                    await model.refreshJobs()
                    if let shown = model.jobDetail?.job, shown.state.isActive,
                       let finished = model.jobs.first(where: { $0.id == shown.id && !$0.state.isActive }) {
                        await model.inspectJob(finished)
                    }
                    guard model.jobs.contains(where: { $0.state.isActive }) else { return }
                    try? await Task.sleep(for: .seconds(2))
                }
            }
        } label: {
            HStack {
                Text("Linux jobs").font(.subheadline.weight(.semibold))
                let active = model.jobs.filter { $0.state.isActive }.count
                if active > 0 {
                    Text("\(active) active").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if expanded {
                    Button { Task { await model.refreshJobs() } } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Refresh Linux jobs")
                }
            }
        }
        .onChange(of: model.jobDetail?.job?.id) { _, id in
            if id != nil { expanded = true }
        }
    }

    private func row(_ job: LinuxJob) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                Text(job.title).lineLimit(1)
                Text(shortStatus(job)).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if job.state.canCancel {
                Button("Cancel", role: .destructive) { Task { await model.inspectJob(job, action: "job-cancel") } }
            }
            Button("Details") { Task { await model.inspectJob(job) } }
        }
        .padding(8)
        .background(.fill.tertiary, in: RoundedRectangle(cornerRadius: 6))
        .disabled(model.running != nil)
    }

    private func shortStatus(_ job: LinuxJob) -> String {
        let exit = job.exitCode.map { " · Exit \($0)" } ?? ""
        return job.state.label + exit + " · " + String(job.id.prefix(8))
    }

    private func jobResult(_ job: LinuxJob, reply: PeerReply) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(shortStatus(job)).font(.caption.weight(.semibold))
            if let error = job.error ?? job.artifactError { Text(error).font(.caption).foregroundStyle(.orange) }
            if let output = reply.output, !output.isEmpty {
                ScrollView {
                    Text(output)
                        .textSelection(.enabled)
                        .font(.system(.caption, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 140)
            }
            if let name = job.artifactName {
                Button("Save \(name)…") {
                    Task {
                        if let artifact = await model.fetchArtifact(for: job) { save(artifact) }
                    }
                }
                .disabled(model.running != nil)
            }
        }
        .padding(9)
        .background(.fill.tertiary, in: RoundedRectangle(cornerRadius: 8))
    }

    private func save(_ artifact: BuildArtifact) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = URL(fileURLWithPath: artifact.name).lastPathComponent
        panel.begin { choice in
            guard choice == .OK, let url = panel.url else { return }
            do { try artifact.data.write(to: url, options: .atomic) }
            catch { NSAlert(error: error).runModal() }
        }
    }
}
