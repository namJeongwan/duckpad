import Foundation

public enum DuckpadProject {
    public static let repositoryURL = URL(string: "https://github.com/namJeongwan/duckpad")!
    public static let releasesURL = repositoryURL.appendingPathComponent("releases")
    public static let issuesURL = repositoryURL.appendingPathComponent("issues/new/choose")
    public static let latestReleaseAPI = URL(string: "https://api.github.com/repos/namJeongwan/duckpad/releases/latest")!
}
