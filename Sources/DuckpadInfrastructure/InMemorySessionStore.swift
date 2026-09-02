import DuckpadApplication
import DuckpadDomain

public actor InMemorySessionStore: SessionStore {
    private var session: ScratchSession?
    private var durableGeneration = PersistenceGeneration(rawValue: 0)
    public private(set) var saveCount = 0

    public init(session: ScratchSession? = nil) {
        self.session = session
    }

    public func loadSession() async throws(SessionStoreError) -> StoredSession? {
        session.map { StoredSession(session: $0, generation: durableGeneration) }
    }

    public func commitSession(
        _ session: ScratchSession,
        generation: PersistenceGeneration
    ) async throws(SessionStoreError) -> SessionCommitResult {
        guard generation > durableGeneration else {
            return .superseded(durableGeneration: durableGeneration)
        }
        self.session = session
        durableGeneration = generation
        saveCount += 1
        return .committed
    }

    public func storedSession() -> ScratchSession? {
        session
    }
}
