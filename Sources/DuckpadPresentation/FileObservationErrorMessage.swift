import DuckpadApplication
import DuckpadLocalization

extension FileObservationError {
    var localizedObservationMessage: String {
        switch self {
        case .authentication: L10n.text("SSH connection failed. Check your host, SSH key, and known_hosts entry.")
        case .dirtyDocument: L10n.text("Save or discard your changes before starting Tail mode.")
        case .unsupportedEncoding, .invalidUTF8: L10n.text("Tail and remote viewing currently require a UTF-8 text file.")
        case .tooLarge: L10n.text("Tail paused after 64 MiB of new output. Clear Tail Output to continue.")
        case .remoteFileTooLarge: L10n.text("The file is larger than 64 MiB. Enable Tail to open its recent output.")
        case .cancelled: L10n.text("Cancelled")
        case .timedOut: L10n.text("The SSH request timed out.")
        case .persistence: L10n.text("Could not save the document state. Try again.")
        case .editorUnavailable: L10n.text("This document is not available for Tail mode.")
        case .unavailable: L10n.text("The file is unavailable.")
        case .invalidResponse: L10n.text("The server returned an invalid file response.")
        }
    }
}
