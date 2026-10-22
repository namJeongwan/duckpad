import Darwin
import DuckpadDomain
import Foundation

/// Reads only Host aliases and Include directives. It never evaluates Match
/// exec, asks ssh -G to run configuration commands, or reads private keys.
public struct SSHHostCatalog: Sendable {
    private let home: URL
    public init(home: URL = FileManager.default.homeDirectoryForCurrentUser) { self.home = home }
    public func hosts(configuration: URL? = nil) throws -> [String] {
        var visited = Set<String>(), aliases = Set<String>(), bytes = 0
        var enumerationBudget = 8_192
        func includedPaths(_ pattern: String) throws -> [String] {
            var matches = [String]()
            let components = pattern.split(separator: "/").map(String.init)
            func expand(_ root: String, _ index: Int) throws {
                try Task.checkCancellation()
                guard index < components.count else {
                    if matches.count < 64 { matches.append(root) }; return
                }
                guard matches.count < 64 else { return }
                let component = components[index]
                if !component.contains(where: { "*?[".contains($0) }) {
                    try expand((root as NSString).appendingPathComponent(component), index + 1); return
                }
                guard enumerationBudget > 0, let directory = opendir(root) else { return }
                defer { closedir(directory) }
                while enumerationBudget > 0, matches.count < 64, let entry = readdir(directory) {
                    enumerationBudget -= 1
                    try Task.checkCancellation()
                    let name = withUnsafePointer(to: &entry.pointee.d_name) {
                        $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) { String(cString: $0) }
                    }
                    guard name != ".", name != "..", fnmatch(component, name, FNM_PERIOD) == 0 else { continue }
                    try expand((root as NSString).appendingPathComponent(name), index + 1)
                }
            }
            try expand("/", 0)
            return matches.sorted()
        }
        func read(_ url: URL, relativeTo base: URL) throws {
            try Task.checkCancellation()
            let path = url.standardizedFileURL.path
            guard visited.count < 64, visited.insert(path).inserted else { return }
            let descriptor = Darwin.open(url.path, O_RDONLY | O_NONBLOCK | O_CLOEXEC)
            guard descriptor >= 0 else { return }
            let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
            defer { try? handle.close() }
            var info = stat()
            guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { return }
            guard let data = try handle.read(upToCount: 1_024 * 1_024 + 1), data.count <= 1_024 * 1_024 else { return }
            bytes += data.count
            guard bytes <= 4 * 1_024 * 1_024, let text = String(data: data, encoding: .utf8) else { return }
            for line in text.split(whereSeparator: \.isNewline) {
                try Task.checkCancellation()
                let parts = Self.tokens(String(line))
                guard let directive = parts.first?.lowercased() else { continue }
                if directive == "host" {
                    for alias in parts.dropFirst() where aliases.count < 4_096 {
                        if RemoteFileLocation(host: alias, path: "/") != nil { aliases.insert(alias) }
                    }
                } else if directive == "include" {
                    for value in parts.dropFirst() {
                        let expanded: String
                        if value.hasPrefix("~/") { expanded = home.appendingPathComponent(String(value.dropFirst(2))).path }
                        else if value.hasPrefix("/") { expanded = value }
                        else { expanded = base.appendingPathComponent(value).path }
                        // Unexpanded SSH tokens/environment conditions are left
                        // to OpenSSH; discovery does not execute configuration.
                        guard !expanded.contains("%"), !expanded.contains("${") else { continue }
                        for name in try includedPaths(expanded) {
                            try read(URL(fileURLWithPath: name), relativeTo: base)
                        }
                    }
                }
            }
        }
        if let configuration { try read(configuration, relativeTo: home.appendingPathComponent(".ssh")) }
        else {
            try read(home.appendingPathComponent(".ssh/config"), relativeTo: home.appendingPathComponent(".ssh"))
            try read(URL(fileURLWithPath: "/etc/ssh/ssh_config"), relativeTo: URL(fileURLWithPath: "/etc/ssh"))
        }
        return aliases.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }
    static func tokens(_ line: String) -> [String] {
        var result = [String](), current = "", quoted = false, escaped = false
        for c in line {
            if escaped { current.append(c); escaped = false; continue }
            if c == "\\" { escaped = true; continue }
            if c == "\"" { quoted.toggle(); continue }
            if c == "#", !quoted { break }
            if !quoted, c.isWhitespace || c == "=" {
                if !current.isEmpty { result.append(current); current = "" }
            } else { current.append(c) }
        }
        if !current.isEmpty { result.append(current) }
        return result
    }
}
