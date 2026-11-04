import Foundation
import DuckpadDomain

public enum LanguageInterpreterResolver {
    public static func resolve(rule: LanguageServiceInterpreter?, settings: LanguageServiceSettings, root: URL, searchPaths: [String], workspaceID: SessionID? = nil, folder: LanguageServiceFolder? = nil) throws -> String? {
        guard let rule else { return nil }
        func executable(_ path: String) -> Bool {
            var directory: ObjCBool = false
            return FileManager.default.fileExists(atPath: path, isDirectory: &directory) && !directory.boolValue
                && FileManager.default.isExecutableFile(atPath: path)
        }
        let workspace = workspaceID.map { settings.workspace($0) }
        let project = workspace?.folderSettings(folder, projectRoot: root.path).interpreterPath
            ?? settings.projects[root.path]?.interpreterPath ?? ""
        let workspacePath = workspace?.interpreterPath ?? ""
        let selected: String?
        if !project.isEmpty { selected = project }
        else if !workspacePath.isEmpty { selected = workspacePath }
        else if let local = rule.projectPaths.map({ root.appendingPathComponent($0).path }).first(where: executable) { selected = local }
        else if !settings.interpreterPath.isEmpty { selected = settings.interpreterPath }
        else { selected = searchPaths.lazy.flatMap { path in rule.executableNames.map { path + "/" + $0 } }.first(where: executable) }
        if let selected, !executable(selected) { throw CocoaError(.fileNoSuchFile) }
        return selected // Preserve venv symlinks to retain their package environment.
    }
}
