import Foundation

/// A tool could not run because macOS has not granted Deckard a privacy
/// permission. Only the person at the Mac can fix this, so the message is
/// written for a remote agent to relay: what is missing, where to grant it,
/// and that retrying before then is pointless.
///
/// Thrown by service adapters; `MCPHostBuilder` returns `description` to the
/// caller as-is and audits the failure with the service name.
public struct MacPermissionError: Error, Sendable, Equatable, CustomStringConvertible {
    public enum Service: String, Sendable {
        case calendar, reminders, contacts, mail, iCloudDrive = "icloud_drive", voiceMemos = "voice_memos"

        var displayName: String {
            switch self {
            case .calendar: return "Calendar"
            case .reminders: return "Reminders"
            case .contacts: return "Contacts"
            case .mail: return "Mail"
            case .iCloudDrive: return "iCloud Drive"
            case .voiceMemos: return "Voice Memos"
            }
        }

        /// Where in System Settings > Privacy & Security the switch lives.
        var settingsPath: String {
            switch self {
            case .calendar: return "Calendars (set Deckard to Full Access)"
            case .reminders: return "Reminders (set Deckard to Full Access)"
            case .contacts: return "Contacts"
            case .mail: return "Automation > Deckard > Mail"
            case .iCloudDrive: return "Files and Folders > Deckard > iCloud Drive"
            case .voiceMemos: return "Full Disk Access, or allow the \"access data from other apps\" prompt"
            }
        }
    }

    public enum State: String, Sendable {
        /// macOS has never been asked, or the request is still unanswered: a
        /// permission prompt is on the Mac's screen right now.
        case promptPending = "prompt_pending"
        /// Access was refused, or is blocked by a profile or parental control.
        case denied
    }

    public let service: Service
    public let state: State

    public init(_ service: Service, _ state: State) {
        self.service = service
        self.state = state
    }

    public var description: String {
        let app = service.displayName
        switch state {
        case .promptPending:
            return "macOS permission required: Deckard has not been allowed to use \(app) yet. "
                + "A permission prompt should be showing on the Mac's screen now; someone at the Mac must click Allow. "
                + "If no prompt is visible, open System Settings > Privacy & Security > \(service.settingsPath) and enable Deckard. "
                + "This cannot be fixed remotely. Tell the user, and retry only after they confirm it is granted."
        case .denied:
            return "macOS permission required: Deckard is not allowed to use \(app) on this Mac. "
                + "Someone at the Mac must open System Settings > Privacy & Security > \(service.settingsPath) and enable Deckard. "
                + "This cannot be fixed remotely. Tell the user, and retry only after they confirm it is granted."
        }
    }
}

/// Service-specific errors that may represent a missing macOS permission
/// adopt this so the host can recognize them without importing the service.
public protocol MacPermissionConvertible {
    var macPermissionError: MacPermissionError? { get }
}

extension MacPermissionError {
    /// Recognizes a missing-permission failure in whatever a tool threw.
    /// `tool` disambiguates bare filesystem "operation not permitted" errors,
    /// which carry no hint of which protected location was involved.
    static func classify(_ error: any Error, tool: String) -> MacPermissionError? {
        if let known = error as? MacPermissionError { return known }
        if let convertible = error as? any MacPermissionConvertible { return convertible.macPermissionError }

        let ns = error as NSError
        let isFilePermission =
            (ns.domain == NSCocoaErrorDomain && (ns.code == NSFileReadNoPermissionError || ns.code == NSFileWriteNoPermissionError))
            || (ns.domain == NSPOSIXErrorDomain && (ns.code == Int(EPERM) || ns.code == Int(EACCES)))
        guard isFilePermission else { return nil }
        if tool.hasPrefix("drive.") { return MacPermissionError(.iCloudDrive, .denied) }
        if tool.hasPrefix("voice_memo.") { return MacPermissionError(.voiceMemos, .denied) }
        return nil
    }
}
