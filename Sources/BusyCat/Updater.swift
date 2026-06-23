import Foundation

/// Lightweight update check: ask the GitHub Releases API for the latest tag and
/// compare it to the running version. No signing, no Sparkle framework — just a
/// hint in the menu. Distribution stays manual (`git pull && make_app.sh`).
enum Updater {
    static let repo = "mangomandu/busycat"
    static let releasesPage = URL(string: "https://github.com/\(repo)/releases/latest")!

    /// Running version from CFBundleShortVersionString (e.g. "1.0").
    static var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
    }

    /// Numeric compare so "1.10" > "1.9".
    static func isNewer(_ a: String, than b: String) -> Bool {
        a.compare(b, options: .numeric) == .orderedDescending
    }

    /// Fetch the latest release tag; call back on the main queue with the newer
    /// version string (e.g. "1.1") if it beats what's running, else nil. Silent
    /// on any error or when the repo has no releases yet (API 404).
    static func check(completion: @escaping (String?) -> Void) {
        let url = URL(string: "https://api.github.com/repos/\(repo)/releases/latest")!
        var req = URLRequest(url: url, timeoutInterval: 10)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        URLSession.shared.dataTask(with: req) { data, _, _ in
            var newer: String?
            if let data,
               let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               var tag = obj["tag_name"] as? String {
                if tag.hasPrefix("v") { tag.removeFirst() }
                if isNewer(tag, than: currentVersion) { newer = tag }
            }
            DispatchQueue.main.async { completion(newer) }
        }.resume()
    }
}
