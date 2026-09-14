public struct FormattingSettings: Codable, Equatable, Sendable {
    public var formatOnSave = false
    public var tabWidth = 2
    public var useTabs = false
    public var printWidth = 80
    public var singleQuote = false
    public var semicolons = true
    public var sqlDialect: SQLFormattingDialect = .sql

    public init() {}
}

public enum SQLFormattingDialect: String, CaseIterable, Codable, Sendable {
    case sql, postgresql, mysql, mariadb, plsql, sqlite, transactsql

    public var displayName: String {
        switch self {
        case .sql: "SQL"
        case .postgresql: "PostgreSQL"
        case .mysql: "MySQL"
        case .mariadb: "MariaDB"
        case .plsql: "Oracle"
        case .sqlite: "SQLite"
        case .transactsql: "SQL Server"
        }
    }
}
