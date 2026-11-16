import DuckpadDomain

@MainActor
public protocol SearchPreviewSyntaxHighlighting: AnyObject {
    func highlight(_ preview: SearchMatchPreview, filename: String?, languageOverride: LanguageOverride) -> SearchMatchPreview
}
