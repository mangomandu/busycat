import Foundation

/// Lightweight update check: ask the GitHub Releases API for the latest tag and
/// compare it to the running version. No signing, no Sparkle framework — just a
/// hint in the menu. Distribution stays manual (`git pull && make_app.sh`).
enum Updater {
    enum CheckResult: Equatable {
        case updateAvailable(String)
        case upToDate
        case failed
    }

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

    static func interpretLatestRelease(
        statusCode: Int?, data: Data?, currentVersion: String
    ) -> CheckResult {
        guard let statusCode, (200..<300).contains(statusCode), let data,
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              var tag = obj["tag_name"] as? String
        else { return .failed }

        if tag.first?.lowercased() == "v" { tag.removeFirst() }
        guard !tag.isEmpty else { return .failed }
        return isNewer(tag, than: currentVersion) ? .updateAvailable(tag) : .upToDate
    }

    /// Fetch the latest release tag and distinguish a successful no-update result
    /// from network, HTTP, and response-decoding failures.
    static func check(completion: @escaping (CheckResult) -> Void) {
        let url = URL(string: "https://api.github.com/repos/\(repo)/releases/latest")!
        var req = URLRequest(url: url, timeoutInterval: 10)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        URLSession.shared.dataTask(with: req) { data, response, error in
            let statusCode = (response as? HTTPURLResponse)?.statusCode
            let result = error == nil
                ? interpretLatestRelease(statusCode: statusCode, data: data,
                                         currentVersion: currentVersion)
                : .failed
            DispatchQueue.main.async { completion(result) }
        }.resume()
    }
}
