import AppKit

/// UI state for one update in the table.
@MainActor
final class UpdateRow {
    enum Status: Equatable {
        case idle
        case waiting
        case working(String)
        case installed
        case handedOff(String)
        case failed(String)

        var text: String {
            switch self {
            case .idle: return ""
            case .waiting: return "Waiting"
            case .working(let step): return step
            case .installed: return "Updated"
            case .handedOff(let message): return message
            case .failed(let message): return "Failed: \(message)"
            }
        }

        var isFinished: Bool {
            switch self {
            case .installed, .handedOff: return true
            default: return false
            }
        }
    }

    let update: AvailableUpdate
    var isChecked = true
    var status: Status = .idle
    /// Release notes fetched from the appcast's release notes link.
    var fetchedNotes: NSAttributedString?

    init(update: AvailableUpdate) {
        self.update = update
    }

    var name: String { update.app.name }
}
