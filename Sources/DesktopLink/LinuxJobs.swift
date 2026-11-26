import Foundation

struct LinuxJobPreset: Codable, Identifiable, Equatable, Sendable {
    let id: String
    let name: String
}

enum LinuxJobState: String, Decodable, Sendable {
    case queued
    case running
    case cancelling
    case succeeded
    case failed
    case cancelled

    var isActive: Bool { self == .queued || self == .running || self == .cancelling }
    var canCancel: Bool { self == .queued || self == .running }

    var label: String {
        switch self {
        case .queued: "Queued"
        case .running: "Running"
        case .cancelling: "Cancelling"
        case .succeeded: "Succeeded"
        case .failed: "Failed"
        case .cancelled: "Cancelled"
        }
    }
}

struct LinuxJob: Decodable, Identifiable, Equatable, Sendable {
    let id: String
    let project: String
    let preset: String
    let title: String
    let state: LinuxJobState
    let updatedAt: TimeInterval
    let exitCode: Int?
    let elapsedMs: Int?
    let artifactName: String?
    let artifactError: String?
    let error: String?
}
