import Foundation
import DuckpadApplication
import DuckpadDomain
import DuckpadLocalization

/// Translate typed failures at the UI boundary, keeping domain and persistence
/// independent of the current display language. Paths and engine diagnostics are data.
enum PresentationErrorText {
    static func message(_ error: any Error, catalog: LocalizationCatalog = L10n.catalog) -> String {
        switch error {
        case let failure as SearchFailure:
            switch failure {
            case .emptyPattern: return catalog.text("Enter text to search.")
            case .invalidExtendedEscape, .invalidRegularExpression: return catalog.text("The search expression is invalid.")
            case .documentTooLarge, .patternTooLarge, .invalidLimits, .tooComplex: return catalog.text("The operation exceeds the supported size or complexity limit.")
            case .timedOut: return catalog.text("The operation timed out. Try a simpler search.")
            case .staleRevision, .invalidSelection: return catalog.text("The document or selection changed. Try again.")
            case .noSelection: return catalog.text("Select a non-empty range to search")
            case .cancelled: return catalog.text("Cancelled")
            case .invalidUTF8Range, .replacementFailed, .unsupportedReplacement: return catalog.text("The replacement could not be applied. Check the expression and selection.")
            }
        case let failure as FolderSearchFailure:
            switch failure {
            case .search(let nested): return message(nested, catalog: catalog)
            case .accessDenied: return catalog.text("Permission denied. Open the file or folder again to restore access.")
            case .invalidRoot, .enumerationFailed: return catalog.text("The folder is unavailable. Choose it again.")
            case .invalidLimits: return catalog.text("The operation exceeds the supported size or complexity limit.")
            }
        case let failure as WorkspaceBrowserFailure:
            switch failure {
            case .invalidPath, .unavailableRoot, .unknownRoot: return catalog.text("The folder is unavailable. Choose it again.")
            case .duplicateRoot: return catalog.text("This folder is already in the workspace.")
            case .rootLimitExceeded, .entryLimitExceeded, .fileTooLarge: return catalog.text("The operation exceeds the supported size or complexity limit.")
            case .permissionDenied: return catalog.text("Permission denied. Open the file or folder again to restore access.")
            case .cancelled: return catalog.text("Cancelled")
            case .corruptStore: return catalog.text("Saved data could not be read. Your document contents have been kept.")
            case .io: return catalog.text("The file or folder operation could not be completed.")
            }
        case let failure as AppSettingsStoreError:
            switch failure {
            case .corrupt, .readFailed, .unsupportedSchema: return catalog.text("Saved preferences could not be read.")
            case .writeFailed: return catalog.text("Preferences could not be written to disk.")
            case .writeUncertain: return catalog.text("The preferences file is visible, but its durable storage could not be confirmed.")
            }
        case let failure as FileOperationFailure:
            switch failure {
            case .readOnly: return catalog.text("Binary files are read-only and cannot be saved.")
            case .store(let nested): return message(nested, catalog: catalog)
            case .workspace(let nested): return message(nested, catalog: catalog)
            case .cancelled: return catalog.text("Cancelled")
            case .unsavedChanges: return catalog.text("This document has unsaved changes.")
            case .noActiveDocument, .editorSnapshotUnavailable: return catalog.text("The document is unavailable. Select an open document and try again.")
            case .editorRevisionMismatch, .comparisonInvalidated: return catalog.text("The document or selection changed. Try again.")
            case .comparisonTooLarge: return catalog.text("The operation exceeds the supported size or complexity limit.")
            case .codec: return catalog.text("The text cannot be read or saved with this encoding. Choose another encoding.")
            case .session: return catalog.text("Saved data could not be read. Your document contents have been kept.")
            }
        case let failure as TextFileStoreError:
            switch failure {
            case .notFound, .invalidPath: return catalog.text("This file is no longer available.")
            case .permissionDenied: return catalog.text("Permission denied. Open the file or folder again to restore access.")
            case .conflict: return catalog.text("The file changed outside Duckpad.")
            case .atomicWriteFailed, .io: return catalog.text("The file or folder operation could not be completed.")
            case .durabilityFailure(let state, _, let recoveryPath, _):
                let description: String
                switch state {
                case .originalRestored: description = catalog.text("Saving failed. The original file was restored; your edits remain open.")
                case .replacementVisibleDurabilityUncertain: description = catalog.text("The new file is visible, but durable storage could not be confirmed. Keep your edits open.")
                case .filesystemStateUncertain: description = catalog.text("The file state could not be confirmed. Keep your edits open and check the file before retrying.")
                }
                return recoveryPath.map { catalog.text("%1$@\nRecovery copy: %2$@", arguments: [description, $0]) } ?? description
            }
        case let failure as OpenDocumentComparison.Error:
            switch failure {
            case .sameTab: return catalog.text("Choose another open document.")
            case .missingTab, .missingSnapshot: return catalog.text("The document is unavailable. Select an open document and try again.")
            case .staleSnapshot: return catalog.text("The document or selection changed. Try again.")
            case .inputTooLarge, .tooManyLines, .complexityExceeded: return catalog.text("The operation exceeds the supported size or complexity limit.")
            case .cancelled: return catalog.text("Cancelled")
            }
        case let failure as ExtensionFailure:
            switch failure {
            case .busy: return catalog.text("An extension command is already running.")
            case .cancelled: return catalog.text("Cancelled")
            case .timedOut: return catalog.text("The extension command timed out.")
            case .disabled, .permissionDenied: return catalog.text("Enable the extension and review its requested permissions.")
            case .untrustedPublisher, .signatureMismatch: return catalog.text("The extension publisher or signature could not be verified.")
            case .staleContext: return catalog.text("The document or selection changed. Try again.")
            case .limitExceeded: return catalog.text("The operation exceeds the supported size or complexity limit.")
            case .unsupportedAPI: return catalog.text("This extension is incompatible with this version of Duckpad.")
            case .malformedManifest, .unknownCapability, .invalidPackagePath, .duplicateIdentifier, .unknownCommand, .invalidModule, .hostUnavailable, .invalidResult:
                return catalog.text("The extension could not be loaded or its command could not be completed.")
            }
        case let failure as PersistenceFailure: return message(failure.cause, catalog: catalog)
        case let failure as SessionStoreError:
            switch failure {
            case .corrupt: return catalog.text("Saved data could not be read. Your document contents have been kept.")
            case .unavailable: return catalog.text("Session storage is unavailable. Keep the app open and retry saving.")
            }
        default: return catalog.text("The operation could not be completed. Try again.")
        }
    }
}
