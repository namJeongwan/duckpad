import Foundation
import DuckpadApplication
import DuckpadDomain
import DuckpadLocalization

/// Translate typed failures at the UI boundary, keeping domain and persistence
/// independent of the current display language. Paths and engine diagnostics are data.
enum PresentationErrorText {
    static func message(_ error: any Error) -> String {
        switch error {
        case let failure as SearchFailure:
            switch failure {
            case .emptyPattern: return L10n.text("Enter text to search.")
            case .invalidExtendedEscape, .invalidRegularExpression: return L10n.text("The search expression is invalid.")
            case .documentTooLarge, .patternTooLarge, .invalidLimits, .tooComplex: return L10n.text("The operation exceeds the supported size or complexity limit.")
            case .timedOut: return L10n.text("The operation timed out. Try a simpler search.")
            case .staleRevision, .invalidSelection: return L10n.text("The document or selection changed. Try again.")
            case .noSelection: return L10n.text("Select a non-empty range to search")
            case .cancelled: return L10n.text("Cancelled")
            case .invalidUTF8Range, .replacementFailed, .unsupportedReplacement: return L10n.text("The replacement could not be applied. Check the expression and selection.")
            }
        case let failure as FolderSearchFailure:
            switch failure {
            case .search(let nested): return message(nested)
            case .accessDenied: return L10n.text("Permission denied. Open the file or folder again to restore access.")
            case .invalidRoot, .enumerationFailed: return L10n.text("The folder is unavailable. Choose it again.")
            case .invalidLimits: return L10n.text("The operation exceeds the supported size or complexity limit.")
            }
        case let failure as WorkspaceBrowserFailure:
            switch failure {
            case .invalidPath, .unavailableRoot, .unknownRoot: return L10n.text("The folder is unavailable. Choose it again.")
            case .duplicateRoot: return L10n.text("This folder is already in the workspace.")
            case .rootLimitExceeded, .entryLimitExceeded, .fileTooLarge: return L10n.text("The operation exceeds the supported size or complexity limit.")
            case .permissionDenied: return L10n.text("Permission denied. Open the file or folder again to restore access.")
            case .cancelled: return L10n.text("Cancelled")
            case .corruptStore: return L10n.text("Saved data could not be read. Your document contents have been kept.")
            case .io: return L10n.text("The file or folder operation could not be completed.")
            }
        case let failure as AppSettingsStoreError:
            switch failure {
            case .corrupt, .readFailed, .unsupportedSchema: return L10n.text("Saved preferences could not be read.")
            case .writeFailed: return L10n.text("Preferences could not be written to disk.")
            case .writeUncertain: return L10n.text("The preferences file is visible, but its durable storage could not be confirmed.")
            }
        case let failure as FileOperationFailure:
            switch failure {
            case .store(let nested): return message(nested)
            case .workspace(let nested): return message(nested)
            case .cancelled: return L10n.text("Cancelled")
            case .unsavedChanges: return L10n.text("This document has unsaved changes.")
            case .noActiveDocument, .editorSnapshotUnavailable: return L10n.text("The document is unavailable. Select an open document and try again.")
            case .editorRevisionMismatch, .comparisonInvalidated: return L10n.text("The document or selection changed. Try again.")
            case .comparisonTooLarge: return L10n.text("The operation exceeds the supported size or complexity limit.")
            case .codec: return L10n.text("The text cannot be read or saved with this encoding. Choose another encoding.")
            case .session: return L10n.text("Saved data could not be read. Your document contents have been kept.")
            }
        case let failure as TextFileStoreError:
            switch failure {
            case .notFound, .invalidPath: return L10n.text("This file is no longer available.")
            case .permissionDenied: return L10n.text("Permission denied. Open the file or folder again to restore access.")
            case .conflict: return L10n.text("The file changed outside Duckpad.")
            case .atomicWriteFailed, .io: return L10n.text("The file or folder operation could not be completed.")
            case .durabilityFailure(let state, _, let recoveryPath, _):
                let description: String
                switch state {
                case .originalRestored: description = L10n.text("Saving failed. The original file was restored; your edits remain open.")
                case .replacementVisibleDurabilityUncertain: description = L10n.text("The new file is visible, but durable storage could not be confirmed. Keep your edits open.")
                case .filesystemStateUncertain: description = L10n.text("The file state could not be confirmed. Keep your edits open and check the file before retrying.")
                }
                return recoveryPath.map { L10n.text("%1$@\nRecovery copy: %2$@", description, $0) } ?? description
            }
        case let failure as OpenDocumentComparison.Error:
            switch failure {
            case .sameTab: return L10n.text("Choose another open document.")
            case .missingTab, .missingSnapshot: return L10n.text("The document is unavailable. Select an open document and try again.")
            case .staleSnapshot: return L10n.text("The document or selection changed. Try again.")
            case .inputTooLarge, .tooManyLines, .complexityExceeded: return L10n.text("The operation exceeds the supported size or complexity limit.")
            case .cancelled: return L10n.text("Cancelled")
            }
        case let failure as ExtensionFailure:
            switch failure {
            case .busy: return L10n.text("An extension command is already running.")
            case .cancelled: return L10n.text("Cancelled")
            case .timedOut: return L10n.text("The extension command timed out.")
            case .disabled, .permissionDenied: return L10n.text("Enable the extension and review its requested permissions.")
            case .untrustedPublisher, .signatureMismatch: return L10n.text("The extension publisher or signature could not be verified.")
            case .staleContext: return L10n.text("The document or selection changed. Try again.")
            case .limitExceeded: return L10n.text("The operation exceeds the supported size or complexity limit.")
            case .unsupportedAPI: return L10n.text("This extension is incompatible with this version of Duckpad.")
            case .malformedManifest, .unknownCapability, .invalidPackagePath, .duplicateIdentifier, .unknownCommand, .invalidModule, .hostUnavailable, .invalidResult:
                return L10n.text("The extension could not be loaded or its command could not be completed.")
            }
        case let failure as PersistenceFailure: return message(failure.cause)
        case let failure as SessionStoreError:
            switch failure {
            case .corrupt: return L10n.text("Saved data could not be read. Your document contents have been kept.")
            case .unavailable: return L10n.text("Session storage is unavailable. Keep the app open and retry saving.")
            }
        default: return L10n.text("The operation could not be completed. Try again.")
        }
    }
}
