import DuckpadApplication
import DuckpadDomain

/// A bulk choice is valid only for the exact dirty revisions presented.
struct TerminationBatchDecision {
    let tabs: [TabSnapshot]
    let choice: CloseDecision

    func decision(for tab: TabSnapshot) -> CloseDecision? {
        tabs.contains { $0.id == tab.id && $0.buffer == tab.buffer && $0.isDirty == tab.isDirty }
            ? choice : nil
    }
}
